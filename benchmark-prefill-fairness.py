#!/usr/bin/env python3
"""Bounded synthetic mixed-load fairness proof; normal clients must be paused.

Uses the same server scheduler as the Anthropic route, with OpenAI id_slot
extensions to isolate the test's own cache and requests. Never executes model
output or interrupts another request. JSON results go to stdout.
"""
import argparse
import json
import socket
import statistics
import threading
import time
import urllib.request


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


class Client:
    def __init__(self, base):
        self.base = base.rstrip('/')

    def request(self, path, body=None, timeout=450):
        return urllib.request.urlopen(urllib.request.Request(
            self.base + path, None if body is None else json.dumps(body).encode(),
            {'Content-Type': 'application/json'}), timeout=timeout)

    def json(self, path, body=None):
        with self.request(path, body, 15) as response:
            return json.load(response)

    def assert_idle(self):
        if any(s['is_processing'] for s in self.json('/slots')):
            raise RuntimeError('Normal requests must be paused; no test started')


class Stream:
    def __init__(self, client, slot, messages, limit, cache=True):
        self.client, self.slot = client, slot
        self.body = {'model': 'oxcoder-9b-q5-k-m', 'messages': messages,
                     'id_slot': slot, 'cache_prompt': cache, 'temperature': 0,
                     'max_tokens': limit, 'stream': True,
                     'stream_options': {'include_usage': True}}
        self.response = None
        self.done = threading.Event()
        self.first = threading.Event()
        self.stop = threading.Event()
        self.error = None
        self.timings, self.usage, self.arrivals = {}, {}, []
        self.content = ''
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.started = time.monotonic()
        self.thread.start()
        return self

    def run(self):
        try:
            complete = False
            with self.client.request('/v1/chat/completions', self.body) as response:
                self.response = response
                for line in response:
                    if self.stop.is_set():
                        break
                    if not line.startswith(b'data: '):
                        continue
                    data = line[6:].strip()
                    if data == b'[DONE]':
                        complete = True
                        break
                    packet = json.loads(data)
                    if 'error' in packet:
                        raise RuntimeError(packet['error'])
                    self.timings = packet.get('timings') or self.timings
                    self.usage = packet.get('usage') or self.usage
                    for choice in packet.get('choices', []):
                        fragment = choice.get('delta', {}).get('content') or ''
                        if fragment:
                            self.content += fragment
                            self.arrivals.append(time.monotonic())
                            self.first.set()
                if not complete and not self.stop.is_set():
                    raise RuntimeError('Incomplete response stream')
        except Exception as error:
            if not self.stop.is_set():
                self.error = repr(error)
        finally:
            self.finished = time.monotonic()
            self.done.set()

    def wait(self, seconds=420):
        if not self.done.wait(seconds):
            raise TimeoutError('Bounded test request timed out')
        if self.error:
            raise RuntimeError(self.error)
        if not self.content:
            raise RuntimeError('Empty test response')

    def cancel(self):
        if self.done.is_set():
            return
        self.stop.set()
        # Disconnect only this harness-owned stream, not a slot/control endpoint.
        try:
            self.response.fp.raw._sock.shutdown(socket.SHUT_RDWR)
        except (AttributeError, OSError):
            pass
        self.thread.join(15)

    def result(self):
        return {'ttft_s': self.arrivals[0] - self.started if self.arrivals else None,
                'wall_s': self.finished - self.started,
                'timings': self.timings, 'usage': self.usage}


def wait_idle(client):
    until = time.monotonic() + 20
    while any(s['is_processing'] for s in client.json('/slots')):
        if time.monotonic() > until:
            raise RuntimeError('Test-owned requests did not drain; stop here')
        time.sleep(.25)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', default='http://127.0.0.1:30000')
    parser.add_argument('--label', required=True)
    parser.add_argument('--long-tokens', type=int, default=80000)
    args = parser.parse_args()
    client = Client(args.base_url)
    client.assert_idle()
    corpus = '\n'.join(f'def clamp_{i}(value):\n    return max({i%13}, min({1000+i}, int(value)))\n'
                       for i in range(6000))
    tokens = client.json('/tokenize', {'content': corpus})['tokens']
    if not 8192 <= args.long_tokens <= 100000 or len(tokens) < args.long_tokens:
        raise ValueError('long-tokens must be 8192-100000 and fit the synthetic corpus')
    short_source = client.json('/detokenize', {'tokens': tokens[:12000]})['content']
    long_source = client.json('/detokenize', {'tokens': tokens[:args.long_tokens]})['content']

    for mixed in (True, False):
        client.assert_idle()
        mode = 'mixed_decode' if mixed else 'pure_prefill'
        messages = [{'role': 'system', 'content': 'You are a concise coding assistant. No reasoning.'},
                    {'role': 'user', 'content': 'Synthetic warm cache case.\n' + short_source + '\nReply READY.'}]
        seed = Stream(client, 3, messages, 12, cache=False).start()
        seed.wait()
        messages += [{'role': 'assistant', 'content': seed.content},
                     {'role': 'user', 'content': 'Reply exactly FAIRNESS_OK.'}]
        generator = cold = warm = None
        cold_task = None
        try:
            if mixed:
                generator = Stream(client, 1, [
                    {'role': 'user', 'content': 'Write 1000 distinct numbered Python utility functions, '
                     'each with a docstring and implementation. Continue until the output limit. '
                     'Do not summarize. Begin now.'}], 4096, cache=False).start()
                if not generator.first.wait(60) or generator.done.is_set():
                    raise RuntimeError('Could not establish a continuing decoder')
            cold = Stream(client, 0, [
                {'role': 'user', 'content': 'Synthetic cold prefill.\n' + long_source + '\nReply COLD_OK.'}],
                8, cache=False).start()
            until = time.monotonic() + 90
            while True:
                slot = client.json('/slots')[0]
                if slot['is_processing'] and slot.get('n_prompt_tokens_processed', 0) >= 2048:
                    cold_task = slot['id_task']
                    break
                if cold.done.is_set() or time.monotonic() > until:
                    raise RuntimeError('Cold prefill overlap was not established')
                time.sleep(.2)
            emit({'phase': 'overlap', 'label': args.label, 'mode': mode, 'cold_task': cold_task})
            warm = Stream(client, 3, messages, 16).start()
            warm.wait()
            cold_at_warm = client.json('/slots')[0]
            cold.wait()
            result = {'label': args.label, 'mode': mode, 'long_tokens': args.long_tokens,
                      'warm': warm.result(), 'cold': cold.result(),
                      'warm_before_cold_first_token': warm.finished < cold.arrivals[0],
                      'cold_slot_at_warm_completion': {k: cold_at_warm.get(k) for k in (
                          'id', 'id_task', 'is_processing', 'n_prompt_tokens_processed', 'n_prompt_tokens_cache')},
                      'correct_warm_answer': warm.content.strip() == 'FAIRNESS_OK'}
            if generator:
                arrivals = [t for t in generator.arrivals if cold.started <= t <= cold.finished]
                gaps = [b-a for a,b in zip(arrivals, arrivals[1:])]
                result['decode_during_prefill'] = {'chunks': len(arrivals),
                    'max_chunk_gap_s': max(gaps) if gaps else None,
                    'median_chunk_gap_s': statistics.median(gaps) if gaps else None,
                    'generator_finished_early': generator.done.is_set()}
            emit(result)
        finally:
            for stream in (warm, cold, generator):
                if stream:
                    stream.cancel()
            wait_idle(client)


if __name__ == '__main__':
    main()
