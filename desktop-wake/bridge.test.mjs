import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { once } from 'node:events'
import { mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const exec = promisify(execFile)
const bridge = fileURLToPath(new URL('./bridge.mjs', import.meta.url))

test('detaches the observed live command and preserves the Desktop stream', { timeout: 12_000 }, async () => {
  // macOS Unix socket paths are limited to 104 bytes.
  const directory = await mkdtemp(join(process.platform === 'darwin' ? '/tmp' : tmpdir(), 'cxwake-test.'))
  const metadata = { threadId: 'thread', turnId: 'turn', itemId: 'call', processId: '21' }
  const { threadId, turnId, itemId, processId } = metadata
  const start = {
    method: 'item/started',
    params: {
      threadId, turnId,
      item: {
        type: 'commandExecution', id: itemId, processId,
        source: 'unifiedExecStartup', command: 'sleep 1', cwd: '/tmp',
      },
    },
  }
  const fixture = `
    const input = require('node:readline').createInterface({ input: process.stdin })
    input.on('line', line => {
      const request = JSON.parse(line)
      const send = message => console.log(JSON.stringify(message))
      if (request.method === 'initialize') {
        send({ id: request.id, result: { experimental: request.params.capabilities.experimentalApi } })
      }
      if (request.method === 'initialized') send(${JSON.stringify(start)})
      if (request.method === 'thread/backgroundTerminals/detach') {
        const expected = ${JSON.stringify(metadata)}
        const detached = Object.entries(expected).every(([key, value]) => request.params[key] === value)
        send({ id: request.id, result: { detached } })
      }
      if (request.method === 'test/exit') {
        const completion = ${JSON.stringify(start)}
        completion.method = 'item/completed'
        send(completion)
      }
    })
  `
  const relay = spawn(process.execPath, [bridge, 'relay', directory, process.execPath, '-e', fixture], {
    stdio: ['pipe', 'pipe', 'inherit'],
  })
  const relayName = `rpc-${relay.pid}`
  const secondRelay = spawn(process.execPath, [bridge, 'relay', directory, process.execPath, '-e', fixture], {
    stdio: ['pipe', 'pipe', 'inherit'],
  })
  const secondRelayName = `rpc-${secondRelay.pid}`
  const secondClosed = once(secondRelay, 'close')
  const secondLines = createInterface({ input: secondRelay.stdout })[Symbol.asyncIterator]()
  const closed = once(relay, 'close')
  const lines = createInterface({ input: relay.stdout })[Symbol.asyncIterator]()
  const send = message => relay.stdin.write(JSON.stringify(message) + '\n')
  const next = async () => JSON.parse((await lines.next()).value)
  const control = async (...args) => JSON.parse((await exec(process.execPath, [bridge, 'control', directory, ...args])).stdout)

  try {
    send({ method: 'initialize', id: 1, params: { capabilities: {} } })
    assert.deepEqual(await next(), { id: 1, result: { experimental: true } })
    assert.equal((await stat(join(directory, relayName))).mode & 0o777, 0o600)
    send({ method: 'initialized' })
    assert.deepEqual(await next(), start)

    assert.deepEqual(await control('list'), [{ ...metadata, relay: relayName, command: 'sleep 1', cwd: '/tmp', detached: false }])
    await assert.rejects(control('detach', relayName, threadId, 'obsolete', itemId, processId), /no longer available/)
    await assert.rejects(control('detach', relayName, threadId, turnId, itemId, '877'), /no longer available/)
    assert.deepEqual(await control('detach', relayName, threadId, turnId, itemId, processId), { detached: true })
    assert.equal((await control('list'))[0].detached, true)
    await assert.rejects(control('detach', relayName, threadId, turnId, itemId, processId), /no longer available/)

    send({ method: 'test/exit' })
    assert.deepEqual(await next(), { ...start, method: 'item/completed' })
    assert.deepEqual(await control('list'), [])

    secondRelay.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n')
    assert.deepEqual(JSON.parse((await secondLines.next()).value), start)
    assert.deepEqual(await control('list'), [{ ...metadata, relay: secondRelayName, command: 'sleep 1', cwd: '/tmp', detached: false }])
    assert.deepEqual(await control('detach', secondRelayName, threadId, turnId, itemId, processId), { detached: true })
  } finally {
    relay.stdin.end()
    secondRelay.stdin.end()
    await Promise.all([closed, secondClosed])
    await rm(directory, { recursive: true, force: true })
  }
})
