// Runs a wasm32-wasi build, the unittests or the example, shared by the browser page and Node. The program runs on a worker, since the page's main thread may not block.
import { channelName, spawn } from "./env.mjs";

/// Runs the compiled program `module` to completion on a worker, with `name` as its `argv[0]`, passing each line it writes to `stdout` or `stderr`. Resolves to the exit status, or 134 (SIGABRT's) when a failed assertion trapped.
export function runProgram(module, name, stdout, stderr) {
	return new Promise((resolve) => {
		const channel = new BroadcastChannel(channelName);
		const worker = spawn(new URL("./main.mjs", import.meta.url));
		const finish = (code) => {
			channel.close();
			worker.terminate();
			resolve(code);
		};
		channel.onmessage = ({ data }) => {
			if ("line" in data) (data.stream === "stdout" ? stdout : stderr)(data.line);
			else if ("trap" in data) {
				stderr(`trapped: ${data.trap}`);
				finish(134);
			} else if ("error" in data) {
				stderr(`could not run: ${data.error}`);
				finish(1);
			} else finish(data.exit);
		};
		worker.postMessage({ module, name });
	});
}

/// The example exits with 1 when it reported errors, as it always should, and with 2 when it could not build or print them.
export const exampleSucceeded = (code) => code === 0 || code === 1;
