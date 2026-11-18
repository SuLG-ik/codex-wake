import { spawn } from 'node:child_process'
import { chmodSync } from 'node:fs'
import { createConnection, createServer } from 'node:net'
import { createInterface } from 'node:readline'
import { randomUUID } from 'node:crypto'

const [mode, socketPath, ...args] = process.argv.slice(2)

function parse(line) {
  try {
    return JSON.parse(line)
  } catch {
    return undefined
  }
}

function control() {
  const [action, threadId, turnId, itemId, processId] = args
  const request = { action, threadId, turnId, itemId, processId }
  const socket = createConnection(socketPath)
  socket.setTimeout(6000, () => socket.destroy(new Error('App server did not answer')))
  socket.on('connect', () => socket.write(JSON.stringify(request) + '\n'))
  createInterface({ input: socket }).once('line', line => {
    const result = parse(line)
    if (result?.error) {
      console.error(result.error)
      process.exitCode = 1
    } else {
      process.stdout.write(line + '\n')
    }
    socket.end()
  })
  socket.on('error', error => {
    console.error(error.message)
    process.exitCode = 1
  })
}

function relay() {
  const [binary, ...childArgs] = args
  const child = spawn(binary, childArgs, { stdio: ['pipe', 'pipe', 'inherit'] })
  const commands = new Map()
  const requests = new Map()
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
      const id = 'desktop-wake-' + randomUUID()
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
else if (mode === 'control') control()
else throw new Error('Expected relay or control')
