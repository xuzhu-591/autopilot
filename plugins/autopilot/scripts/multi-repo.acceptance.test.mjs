/**
 * Acceptance tests: Multi-Repo helper functions
 *
 * Covers lib.sh multi-repo functions, setup.sh auto-detection,
 * and stop-hook.sh prompt injection for multi-repo mode.
 *
 * Run: node --test plugins/autopilot/scripts/multi-repo.acceptance.test.mjs
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execSync } from 'node:child_process';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const LIB_SH = join(__dirname, 'lib.sh');
const SETUP_SH = join(__dirname, 'setup.sh');
const STOP_HOOK_SH = join(__dirname, 'stop-hook.sh');

let tempBase;

before(() => {
  // Verify yq is available — all multi-repo tests depend on it
  try {
    execSync('command -v yq', { stdio: 'pipe' });
  } catch {
    throw new Error('yq is required for multi-repo tests. Install: brew install yq');
  }
  tempBase = mkdtempSync(join(tmpdir(), 'multi-repo-test-'));
});

after(() => {
  if (tempBase) rmSync(tempBase, { recursive: true, force: true });
});

/** Create a unique sub-directory inside tempBase */
function scaffold(name) {
  const dir = join(tempBase, `${name}-${Date.now()}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** Init a bare-minimum git repo */
function gitInit(dir) {
  execSync('git init', { cwd: dir, stdio: 'pipe' });
  execSync('git config user.email "test@test.com"', { cwd: dir, stdio: 'pipe' });
  execSync('git config user.name "Test"', { cwd: dir, stdio: 'pipe' });
}

/** Run a bash snippet that sources lib.sh, returns stdout trimmed */
function runLib(bash, opts = {}) {
  const script = `set -euo pipefail; source "${LIB_SH}"; ${bash}`;
  return execSync(`bash -c '${script.replace(/'/g, "'\\''")}'`, {
    encoding: 'utf8',
    timeout: 10000,
    ...opts,
  }).trim();
}

// ===========================================================================
// 1. lib.sh function tests
// ===========================================================================

describe('check_yq', () => {
  it('should return 0 when yq is installed', () => {
    const code = runLib('check_yq && echo "yes" || echo "no"');
    assert.equal(code, 'yes');
  });
});

describe('discover_repos', () => {
  it('should find 3 sub git repos', () => {
    const dir = scaffold('discover-3');
    for (const name of ['alpha', 'beta', 'gamma']) {
      const sub = join(dir, name);
      mkdirSync(sub);
      gitInit(sub);
    }
    const output = runLib('discover_repos', { cwd: dir });
    const lines = output.split('\n').filter(Boolean);
    assert.equal(lines.length, 3);
    assert.ok(lines.every(l => l.startsWith('/')), 'all paths should be absolute');
    assert.ok(lines.some(l => l.endsWith('/alpha')));
    assert.ok(lines.some(l => l.endsWith('/beta')));
    assert.ok(lines.some(l => l.endsWith('/gamma')));
  });

  it('should return empty for directory with no git repos', () => {
    const dir = scaffold('discover-empty');
    const output = runLib('discover_repos', { cwd: dir });
    assert.equal(output, '');
  });

  it('should not discover repos nested deeper than 2 levels', () => {
    const dir = scaffold('discover-deep');
    const deep = join(dir, 'a', 'b', 'c');
    mkdirSync(deep, { recursive: true });
    gitInit(deep);
    const output = runLib('discover_repos', { cwd: dir });
    assert.equal(output, '');
  });

  it('should deduplicate paths', () => {
    const dir = scaffold('discover-dedup');
    const sub = join(dir, 'repo');
    mkdirSync(sub);
    gitInit(sub);
    const output = runLib('discover_repos', { cwd: dir });
    const lines = output.split('\n').filter(Boolean);
    assert.equal(lines.length, 1);
  });
});

describe('get_repos_file', () => {
  it('should return TASK_DIR/repos.yaml when TASK_DIR is set', () => {
    const output = runLib('TASK_DIR="/tmp/my-task"; get_repos_file');
    assert.equal(output, '/tmp/my-task/repos.yaml');
  });

  it('should return PROJECT_ROOT/.autopilot/repos.yaml when TASK_DIR is empty', () => {
    const output = runLib('PROJECT_ROOT="/tmp/proj"; TASK_DIR=""; get_repos_file');
    assert.equal(output, '/tmp/proj/.autopilot/repos.yaml');
  });
});

describe('generate_repos_yaml', () => {
  it('should generate valid YAML array with 3 repos', () => {
    const dir = scaffold('gen-yaml-3');
    const output = runLib(`
      TASK_DIR="${dir}"
      printf '/a/repo1\\n/b/repo2\\n/c/repo3\\n' | generate_repos_yaml
      cat "$(get_repos_file)"
    `);
    // Verify with yq
    const reposFile = join(dir, 'repos.yaml');
    assert.ok(existsSync(reposFile), 'repos.yaml should exist');

    const count = execSync(`yq 'length' "${reposFile}"`, { encoding: 'utf8' }).trim();
    assert.equal(count, '3');

    const names = execSync(`yq -r '.[].name' "${reposFile}"`, { encoding: 'utf8' }).trim();
    assert.deepEqual(names.split('\n'), ['repo1', 'repo2', 'repo3']);

    const paths = execSync(`yq -r '.[].path' "${reposFile}"`, { encoding: 'utf8' }).trim();
    assert.deepEqual(paths.split('\n'), ['/a/repo1', '/b/repo2', '/c/repo3']);

    // All worktrees should be empty string
    const worktreeCheck = execSync(`yq '[.[].worktree | select(. != "")] | length' "${reposFile}"`, { encoding: 'utf8' }).trim();
    assert.equal(worktreeCheck, '0', 'all worktrees should be empty');

    const involved = execSync(`yq -r '.[].involved' "${reposFile}"`, { encoding: 'utf8' }).trim();
    assert.deepEqual(involved.split('\n'), ['false', 'false', 'false']);
  });

  it('should generate empty array for empty stdin', () => {
    const dir = scaffold('gen-yaml-empty');
    runLib(`
      TASK_DIR="${dir}"
      echo "" | generate_repos_yaml
    `);
    const reposFile = join(dir, 'repos.yaml');
    assert.ok(existsSync(reposFile));
    const count = execSync(`yq 'length' "${reposFile}"`, { encoding: 'utf8' }).trim();
    assert.equal(count, '0');
  });

  it('should handle paths with spaces', () => {
    const dir = scaffold('gen-yaml-spaces');
    runLib(`
      TASK_DIR="${dir}"
      printf '/tmp/my project/repo one\\n/tmp/another dir/repo two\\n' | generate_repos_yaml
    `);
    const reposFile = join(dir, 'repos.yaml');
    const names = execSync(`yq -r '.[].name' "${reposFile}"`, { encoding: 'utf8' }).trim();
    assert.deepEqual(names.split('\n'), ['repo one', 'repo two']);
  });
});

describe('set_repo_field', () => {
  it('should update worktree field for specified repo', () => {
    const dir = scaffold('set-field');
    runLib(`
      TASK_DIR="${dir}"
      printf '/a/alpha\\n/b/beta\\n' | generate_repos_yaml
      set_repo_field "alpha" "worktree" "/wt/alpha/autopilot-test"
    `);
    const reposFile = join(dir, 'repos.yaml');
    const wt = execSync(`yq -r '.[] | select(.name == "alpha") | .worktree' "${reposFile}"`, { encoding: 'utf8' }).trim();
    assert.equal(wt, '/wt/alpha/autopilot-test');

    // beta should be unchanged
    const wtBeta = execSync(`yq -r '.[] | select(.name == "beta") | .worktree' "${reposFile}"`, { encoding: 'utf8' }).trim();
    assert.equal(wtBeta, '');
  });
});

describe('set_repo_bool', () => {
  it('should set involved=true for specified repo', () => {
    const dir = scaffold('set-bool');
    runLib(`
      TASK_DIR="${dir}"
      printf '/a/alpha\\n/b/beta\\n/c/gamma\\n' | generate_repos_yaml
      set_repo_bool "beta" "involved" "true"
    `);
    const reposFile = join(dir, 'repos.yaml');
    const val = execSync(`yq -r '.[] | select(.name == "beta") | .involved' "${reposFile}"`, { encoding: 'utf8' }).trim();
    assert.equal(val, 'true');
  });

  it('should not affect other repos', () => {
    const dir = scaffold('set-bool-isolation');
    runLib(`
      TASK_DIR="${dir}"
      printf '/a/alpha\\n/b/beta\\n' | generate_repos_yaml
      set_repo_bool "alpha" "involved" "true"
    `);
    const reposFile = join(dir, 'repos.yaml');
    const betaInvolved = execSync(`yq -r '.[] | select(.name == "beta") | .involved' "${reposFile}"`, { encoding: 'utf8' }).trim();
    assert.equal(betaInvolved, 'false');
  });
});

describe('get_involved_repos', () => {
  it('should return only involved=true repos', () => {
    const dir = scaffold('get-involved');
    const output = runLib(`
      TASK_DIR="${dir}"
      printf '/a/alpha\\n/b/beta\\n/c/gamma\\n' | generate_repos_yaml
      set_repo_bool "alpha" "involved" "true"
      set_repo_bool "gamma" "involved" "true"
      set_repo_field "alpha" "worktree" "/wt/alpha"
      get_involved_repos
    `);
    const lines = output.split('\n').filter(Boolean);
    assert.equal(lines.length, 2);
    assert.ok(lines[0].startsWith('alpha\t'));
    assert.ok(lines[1].startsWith('gamma\t'));
    // alpha should have worktree in output
    assert.ok(lines[0].includes('/wt/alpha'));
  });

  it('should return empty when repos.yaml does not exist', () => {
    const dir = scaffold('get-involved-nofile');
    const output = runLib(`
      TASK_DIR="${dir}"
      get_involved_repos || true
    `);
    assert.equal(output, '');
  });
});

describe('get_all_repos', () => {
  it('should return all repos with 4 columns', () => {
    const dir = scaffold('get-all');
    const output = runLib(`
      TASK_DIR="${dir}"
      printf '/a/alpha\\n/b/beta\\n' | generate_repos_yaml
      set_repo_bool "alpha" "involved" "true"
      get_all_repos
    `);
    const lines = output.split('\n').filter(Boolean);
    assert.equal(lines.length, 2);
    // Each line should have 4 tab-separated fields
    for (const line of lines) {
      const cols = line.split('\t');
      assert.equal(cols.length, 4, `expected 4 columns, got: ${line}`);
    }
    // alpha should be involved=true
    assert.ok(lines[0].endsWith('true'));
    // beta should be involved=false
    assert.ok(lines[1].endsWith('false'));
  });
});

describe('is_multi_repo', () => {
  it('should return 0 when mode is multi-repo', () => {
    const dir = scaffold('is-mr-yes');
    mkdirSync(join(dir, '.autopilot'), { recursive: true });
    writeFileSync(join(dir, '.autopilot', 'autopilot.local.md'), `---
phase: "design"
mode: "multi-repo"
---
`);
    const output = runLib(`
      PROJECT_ROOT="${dir}"
      STATE_FILE="${dir}/.autopilot/autopilot.local.md"
      is_multi_repo && echo "yes" || echo "no"
    `);
    assert.equal(output, 'yes');
  });

  it('should return 1 when mode is single', () => {
    const dir = scaffold('is-mr-no');
    mkdirSync(join(dir, '.autopilot'), { recursive: true });
    writeFileSync(join(dir, '.autopilot', 'autopilot.local.md'), `---
phase: "design"
mode: "single"
---
`);
    const output = runLib(`
      PROJECT_ROOT="${dir}"
      STATE_FILE="${dir}/.autopilot/autopilot.local.md"
      is_multi_repo && echo "yes" || echo "no"
    `);
    assert.equal(output, 'no');
  });
});

// ===========================================================================
// 2. setup.sh integration tests
// ===========================================================================

describe('setup.sh multi-repo auto-detection', () => {
  it('should auto-detect multi-repo and generate repos.yaml', () => {
    const dir = scaffold('setup-auto');
    // Create 2 sub git repos (NOT a git repo itself)
    for (const name of ['svc-a', 'svc-b']) {
      const sub = join(dir, name);
      mkdirSync(sub);
      gitInit(sub);
    }

    let stdout = '';
    try {
      stdout = execSync(
        `bash "${SETUP_SH}" "测试多仓库目标"`,
        {
          cwd: dir,
          encoding: 'utf8',
          timeout: 15000,
          stdio: 'pipe',
          env: { ...process.env, HOME: dir },
        }
      );
    } catch (err) {
      stdout = err.stdout || '';
    }

    // Should have detected multi-repo
    assert.ok(stdout.includes('multi-repo') || stdout.includes('子 git 仓库'), `stdout should mention multi-repo detection: ${stdout}`);

    // repos.yaml should exist somewhere under .autopilot/requirements/
    const reposYaml = execSync(
      `find "${dir}/.autopilot" -name repos.yaml 2>/dev/null | head -1`,
      { encoding: 'utf8' }
    ).trim();
    assert.ok(reposYaml.length > 0, 'repos.yaml should exist');

    // Verify it's valid YAML with 2 entries
    const count = execSync(`yq 'length' "${reposYaml}"`, { encoding: 'utf8' }).trim();
    assert.equal(count, '2');
  });

  it('should fail when non-git dir has no sub repos', () => {
    const dir = scaffold('setup-no-repo');

    let stdout = '';
    let exitedCleanly = false;
    try {
      stdout = execSync(
        `bash "${SETUP_SH}" "测试空目录"`,
        {
          cwd: dir,
          encoding: 'utf8',
          timeout: 15000,
          stdio: 'pipe',
          env: { ...process.env, HOME: dir },
        }
      );
      exitedCleanly = true;
    } catch (err) {
      stdout = err.stdout || '';
    }

    // Should report error about no git repos
    assert.ok(
      stdout.includes('不是 git 仓库') || stdout.includes('未发现'),
      `should report no git repos found: ${stdout}`
    );

    // No state file should be created
    const stateFiles = execSync(
      `find "${dir}" -name "state.md" -o -name "autopilot.local.md" 2>/dev/null`,
      { encoding: 'utf8' }
    ).trim();
    assert.equal(stateFiles, '', 'no state file should be created');
  });

  it('should set mode=multi-repo and repos_file in state frontmatter', () => {
    const dir = scaffold('setup-frontmatter');
    for (const name of ['repo-x', 'repo-y']) {
      const sub = join(dir, name);
      mkdirSync(sub);
      gitInit(sub);
    }

    try {
      execSync(
        `bash "${SETUP_SH}" "验证 frontmatter"`,
        {
          cwd: dir,
          encoding: 'utf8',
          timeout: 15000,
          stdio: 'pipe',
          env: { ...process.env, HOME: dir },
        }
      );
    } catch { /* ignore exit code */ }

    // Find state file
    const stateFile = execSync(
      `find "${dir}/.autopilot" -name "state.md" 2>/dev/null | head -1`,
      { encoding: 'utf8' }
    ).trim();
    assert.ok(stateFile.length > 0, 'state file should exist');

    const content = readFileSync(stateFile, 'utf8');
    assert.ok(content.includes('mode: "multi-repo"'), 'frontmatter should have mode: multi-repo');
    assert.ok(content.includes('repos_file:'), 'frontmatter should have repos_file');
    assert.ok(content.includes('repos.yaml'), 'repos_file should point to repos.yaml');
  });
});

// ===========================================================================
// 3. stop-hook.sh multi-repo prompt injection verification
// ===========================================================================

describe('stop-hook.sh multi-repo prompt branches', () => {
  let stopHookSource;

  before(() => {
    stopHookSource = readFileSync(STOP_HOOK_SH, 'utf8');
  });

  it('design phase should have multi-repo branch with repos.yaml instructions', () => {
    // The design phase should check for mode=multi-repo and inject repo analysis steps
    assert.ok(
      stopHookSource.includes('PHASE" == "design"'),
      'stop-hook should check for design phase'
    );
    assert.ok(
      stopHookSource.includes('MODE" == "multi-repo"'),
      'stop-hook should check for multi-repo mode'
    );
    // Design multi-repo prompt should mention yq and involved
    const designMrMatch = stopHookSource.match(/Multi-repo 关键步骤.*?involved/s);
    assert.ok(designMrMatch, 'design multi-repo prompt should mention repo involvement analysis');
  });

  it('implement phase should have grove worktree creation instructions', () => {
    const implSection = stopHookSource.match(/PHASE" == "implement"[\s\S]*?(?=elif \[)/);
    assert.ok(implSection, 'should have implement phase section');
    const implText = implSection[0];
    assert.ok(
      implText.includes('grove') && implText.includes('worktree'),
      'implement multi-repo prompt should mention grove worktree creation'
    );
    assert.ok(
      implText.includes('yq') || implText.includes('repos.yaml'),
      'implement multi-repo prompt should mention updating repos.yaml'
    );
  });

  it('qa phase should have per-worktree diff instructions', () => {
    const qaSection = stopHookSource.match(/PHASE" == "qa"[\s\S]*?(?=elif \[)/);
    assert.ok(qaSection, 'should have qa phase section');
    const qaText = qaSection[0];
    assert.ok(
      qaText.includes('git -C') || qaText.includes('worktree'),
      'qa multi-repo prompt should mention per-worktree operations'
    );
  });

  it('merge phase should have per-repo commit instructions', () => {
    const mergeSection = stopHookSource.match(/PHASE" == "merge"[\s\S]*?(?=else)/);
    assert.ok(mergeSection, 'should have merge phase section');
    const mergeText = mergeSection[0];
    assert.ok(
      mergeText.includes('commit-agent') || mergeText.includes('Multi-repo merge'),
      'merge multi-repo prompt should mention per-repo commit agent'
    );
    assert.ok(
      mergeText.includes('knowledge') || mergeText.includes('知识'),
      'merge multi-repo prompt should mention knowledge extraction routing'
    );
  });

  it('MULTI_REPO_HINT should be constructed when mode=multi-repo', () => {
    assert.ok(
      stopHookSource.includes('MULTI_REPO_HINT'),
      'should define MULTI_REPO_HINT variable'
    );
    assert.ok(
      stopHookSource.includes('REPOS_FILE=$(get_field "repos_file"'),
      'should read repos_file from frontmatter'
    );
  });
});
