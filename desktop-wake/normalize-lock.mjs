import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const workspace = fileURLToPath(new URL('../codex-rs/', import.meta.url))
const metadata = JSON.parse(execFileSync('cargo', ['metadata', '--offline', '--no-deps', '--format-version=1'], {
  cwd: workspace,
  maxBuffer: 32 * 1024 * 1024,
}))
const members = new Set(metadata.workspace_members)
const versions = new Map(metadata.packages.filter(pkg => members.has(pkg.id)).map(pkg => [pkg.name, pkg.version]))
const path = new URL('../codex-rs/Cargo.lock', import.meta.url)
const lock = readFileSync(path, 'utf8')
const normalized = lock.split('[[package]]').map(entry => {
  if (/^source = /m.test(entry)) return entry
  const name = /^name = "([^"]+)"/m.exec(entry)?.[1]
  const version = versions.get(name)
  if (!version) return entry
  return entry.replace(/^version = "0\.0\.0"/m, `version = "${version}"`)
}).join('[[package]]')
if (normalized !== lock) writeFileSync(path, normalized)
