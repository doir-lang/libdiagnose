import { readFile } from "node:fs/promises";
import { exampleSucceeded, runProgram } from "./run.mjs";

const compile = async (path) => WebAssembly.compile(await readFile(path));
const out = (line) => console.log(line);
const err = (line) => console.error(line);

const tests = await runProgram(await compile(process.argv[2]), "diagnose-tests", out, err);
if (tests !== 0) process.exit(tests);
// Node's terminal understands the example's ANSI escapes, so its diagnostics print in color as they would natively.
const example = await runProgram(await compile(process.argv[3]), "diagnose-example", out, err);
process.exit(exampleSucceeded(example) ? 0 : example);
