import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";

// Requires Tern's headless renderer (TERN_BIN can name a specific build). No installed plugin, real HOME,
// usage cache, credentials, daemon socket, provider endpoint or network fixture participates in this test.
test("Luau snapshot reader executes isolated merge, expiry and asynchronous discovery regressions", { timeout: 45000 }, async () => {
  const root = await mkdtemp(path.join(tmpdir(), "omp-cache-reader-"));
  const config = path.join(root, "config");
  const plugin = path.join(config, "plugins", "cache-reader-regression");
  const fixtures = path.join(root, "snapshots");
  const result = path.join(root, "result.json");
  let child;
  let exited;
  let output = "";
  try {
    await mkdir(plugin, { recursive: true });
    await mkdir(fixtures);
    await mkdir(path.join(root, "home"));
    await copyFile(new URL("../cache.luau", import.meta.url), path.join(plugin, "cache.luau"));
    await copyFile(new URL("./cache-reader.test.luau", import.meta.url), path.join(plugin, "window.luau"));
    await copyFile(new URL("./cache-reader-cases.luau", import.meta.url), path.join(plugin, "cache-reader-cases.luau"));
    await writeFile(path.join(plugin, "plugin.toml"), [
      "schema = 1", 'id = "cache-reader-regression"', 'name = "Cache Reader Regression"',
      'version = "0.0.0"', 'window = "window.luau"', "",
    ].join("\n"));
    await writeFile(path.join(fixtures, "123-00000000-0000-4000-8000-000000000001.json"), JSON.stringify({
      generatedAt: 2000000000, fetchedAt: 2000000000, models: {},
      providers: { synthetic: { line: "Disk 5h 42%", fetchedAt: 2000000000, maxAgeMs: 600000 } },
    }));
    child = spawn(process.env.TERN_BIN || "tern", ["serve", "--control", path.join(root, "control.sock"), "--out", path.join(root, "shots")], {
      cwd: root,
      env: {
        ...process.env,
        HOME: path.join(root, "home"), USERPROFILE: path.join(root, "home"),
        XDG_CONFIG_HOME: config, TERN_CONFIG_DIR: config,
        TERN_DAEMON_SOCKET: path.join(root, "daemon.sock"), STENCIL_LOG_DIR: path.join(root, "logs"),
        CACHE_READER_TEST_RESULT: result, CACHE_READER_TEST_FIXTURES: fixtures,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    child.stdout.on("data", (data) => { output += data; });
    child.stderr.on("data", (data) => { output += data; });
    child.on("error", (error) => { exited = `spawn failed: ${error.message}`; });
    child.on("exit", (code, signal) => { exited = `exit ${code ?? signal}`; });
    const until = Date.now() + 35000;
    while (Date.now() < until) {
      let text;
      try { text = await readFile(result, "utf8"); }
      catch (error) { if (error.code !== "ENOENT") throw error; }
      if (text) {
        const report = JSON.parse(text);
        assert.equal(report.ok, true, `${report.error || "Luau regression failed"}\n${output}`);
        return;
      }
      assert.equal(exited, undefined, `Tern ended before executing regressions: ${exited}\n${output}`);
      await delay(50);
    }
    assert.fail(`Timed out waiting for executable Luau regressions\n${output}`);
  } finally {
    if (child && exited === undefined) {
      const ended = new Promise((resolve) => child.once("exit", resolve));
      child.kill("SIGTERM");
      await Promise.race([ended, delay(1000)]);
      if (exited === undefined) child.kill("SIGKILL");
    }
    await rm(root, { recursive: true, force: true });
  }
});
