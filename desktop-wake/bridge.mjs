import { spawn } from 'node:child_process'
import { chmodSync } from 'node:fs'
import { readdir } from 'node:fs/promises'
import { createConnection, createServer } from 'node:net'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { randomUUID } from 'node:crypto'

const [mode, controlDirectory, ...args] = process.argv.slice(2)
const requestPrefix = 'desktop-wake-'
const relaySocketName = /^rpc-\d+$/

function parse(line) {
  try {
    return JSON.parse(line)
  } catch {
    return undefined
  }
}

function requestRelay(relayName, request) {
  return new Promise((resolve, reject) => {
    const socket = createConnection(join(controlDirectory, relayName))
    socket.setTimeout(6000, () => socket.destroy(new Error('App server did not answer')))
    socket.once('error', reject)
    socket.once('close', () => reject(new Error('App server closed before replying')))
    socket.once('connect', () => socket.write(JSON.stringify(request) + '\n'))
    createInterface({ input: socket }).once('line', line => {
      const result = parse(line)
      if (!result || result.error) reject(new Error(result?.error ?? 'Malformed app-server reply'))
      else resolve(result)
      socket.end()
    })
  })
}

async function control() {
  const [action, relayName, threadId, turnId, itemId, processId] = args
  if (action === 'list') {
    const names = (await readdir(controlDirectory)).filter(name => relaySocketName.test(name))
    const results = await Promise.allSettled(names.map(async name => {
      const commands = await requestRelay(name, { action })
      return commands.map(command => ({ ...command, relay: name }))
    }))
    return results.flatMap(result => result.status === 'fulfilled' ? result.value : [])
  }
  if (action !== 'detach' || !relaySocketName.test(relayName)) {
    throw new Error('Unknown control request')
  }
  return requestRelay(relayName, { action, threadId, turnId, itemId, processId })
}

function relay() {
  const [binary, ...childArgs] = args
  const child = spawn(binary, childArgs, { stdio: ['pipe', 'pipe', 'inherit'] })
  const commands = new Map()
  const requests = new Map()
  const socketPath = join(controlDirectory, `rpc-${process.pid}`)
  const key = ({ threadId, turnId, itemId }) => JSON.stringify([threadId, turnId, itemId])
  const write = message => child.stdin.write(JSON.stringify(message) + '\n')
  child.stdin.on('error', () => {})
  let ready = false

  createInterface({ input: process.stdin }).on('line', line => {
    const message = parse(line)
    if (message?.method === 'initialize') {
      message.params.capabilities = {
        ...message.params.capabilities,
        experimentalApi: true,
      }
      write(message)
    } else {
      if (message?.method === 'initialized') ready = true
      child.stdin.write(line + '\n')
    }
  }).on('close', () => child.stdin.end())

  createInterface({ input: child.stdout }).on('line', line => {
    const message = parse(line)
    const pending = requests.get(message?.id)
    if (pending) {
      requests.delete(message.id)
      const detached = message.result?.detached === true
      if (detached) pending.command.detached = true
      const answer = detached
        ? { detached }
        : { error: message.error?.message ?? 'Command already exited or was moved to the background' }
      pending.socket.end(JSON.stringify(answer) + '\n')
      return
    }
    if (typeof message?.id === 'string' && message.id.startsWith(requestPrefix)) return

    const { threadId, turnId, item } = message?.params ?? {}
    if (threadId && turnId && item?.type === 'commandExecution') {
      const command = { threadId, turnId, itemId: item.id, processId: item.processId }
      if (message.method === 'item/completed') commands.delete(key(command))
      if (message.method === 'item/started' && item.source === 'unifiedExecStartup' && item.processId) {
        commands.set(key(command), { ...command, command: item.command, cwd: item.cwd, detached: false })
      }
    }
    if (message?.method === 'thread/closed') {
      for (const [id, command] of commands) {
        if (command.threadId === threadId) commands.delete(id)
      }
    }
    process.stdout.write(line + '\n')
  })

  const server = createServer(socket => {
    socket.setTimeout(5000, () => socket.destroy())
    socket.on('error', () => {})
    let requestText = ''
    socket.setEncoding('utf8')
    const receive = chunk => {
      requestText += chunk
      if (requestText.length > 4096) {
        socket.destroy()
        return
      }
      if (!requestText.includes('\n')) return
      socket.off('data', receive)
      const request = parse(requestText.trim())
      if (request?.action === 'list') {
        socket.end(JSON.stringify([...commands.values()]) + '\n')
        return
      }
      const command = request && commands.get(key(request))
      if (request?.action !== 'detach' || !ready || !command ||
          command.processId !== request.processId || command.detached) {
        socket.end(JSON.stringify({ error: 'Command is no longer available' }) + '\n')
        return
      }
      const id = requestPrefix + randomUUID()
      const { threadId, turnId, itemId, processId } = command
      requests.set(id, { command, socket })
      socket.on('close', () => requests.delete(id))
      write({ id, method: 'thread/backgroundTerminals/detach', params: { threadId, turnId, itemId, processId } })
    }
    socket.on('data', receive)
  })

  server.on('error', error => console.error('Codex Background:', error.message))
  server.listen(socketPath, () => chmodSync(socketPath, 0o600))
  child.on('error', error => console.error('Codex runtime:', error.message))
  child.once('close', (code, signal) => {
    for (const { socket } of requests.values()) socket.destroy()
    server.close()
    process.stdin.destroy()
    process.exitCode = code ?? (signal ? 1 : 0)
  })
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.once(signal, () => child.kill(signal))
  }
}

if (mode === 'relay') relay()
else if (mode === 'control') {
  try {
    process.stdout.write(JSON.stringify(await control()) + '\n')
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
else throw new Error('Expected relay or control')
