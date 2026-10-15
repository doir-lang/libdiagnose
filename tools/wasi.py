#!/usr/bin/env python3
"""Builds the unittests and the example for wasm32-wasi and runs them in a browser, or headlessly under Node, through @tybys/wasm-util's WASI and @emnapi/wasi-threads.

It asks `dub describe` for each configuration's sources and import paths, compiling libfp in alongside. The build links against a wasi-sdk sysroot and compiler-rt builtins, downloaded once into bin/wasi-sdk unless WASI_SYSROOT and WASI_BUILTINS name local copies. It links with `wasm-ld` from PATH (or WASM_LD), falling back to LDC's internal linker.

Usage:
  tools/wasi.py            build bin/wasi/diagnose-tests.wasm, bin/wasi/diagnose-example.wasm and the page that runs them
  tools/wasi.py --serve    ... then serve bin/wasi on http://localhost:8000 to open in a browser
  tools/wasi.py --node     ... then run the same page script under Node, exiting with the tests' status
"""
import argparse, functools, glob, http.server, os, shutil, subprocess, sys, tarfile, urllib.request

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, 'bin', 'wasi')
sdk = os.path.join(root, 'bin', 'wasi-sdk')
page = os.path.join(root, 'tests', 'wasi')
compiler = os.environ.get('DC', 'ldc2')
tests = os.path.join(out, 'diagnose-tests.wasm')
example = os.path.join(out, 'diagnose-example.wasm')

sdkVersion = '34'
release = f'https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-{sdkVersion}/'
target = 'wasm32-wasip1'
packages = ['@tybys/wasm-util@0.10.4', '@emnapi/wasi-threads@2.2.0']


def fetch(name):
	"""Downloads and unpacks a wasi-sdk release archive into bin/wasi-sdk, unless already there, and returns where it unpacked."""
	dest = os.path.join(sdk, name)
	if not os.path.isdir(dest):
		os.makedirs(sdk, exist_ok=True)
		archive = dest + '.tar.gz'
		print(f'downloading {name}', file=sys.stderr)
		urllib.request.urlretrieve(release + name + '.tar.gz', archive)
		with tarfile.open(archive) as tar:
			tar.extractall(sdk, filter='data')
		os.remove(archive)
	return dest


def describe(config, *args):
	result = subprocess.run(['dub', 'describe', *args, '-c', config, '--compiler=' + compiler],
		cwd=root, capture_output=True, text=True)
	if result.returncode != 0:
		sys.exit(result.stdout + result.stderr)
	return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def link(config, wasm, flags):
	"""Compiles dub configuration `config` with the extra compiler `flags` and links it into `wasm`."""
	sysroot = os.environ.get('WASI_SYSROOT') or fetch(f'wasi-sysroot-{sdkVersion}.0')
	builtins = os.environ.get('WASI_BUILTINS') or os.path.join(
		fetch(f'libclang_rt-{sdkVersion}.0'), 'wasm32-unknown-wasip1', 'libclang_rt.builtins.a')
	libs = os.path.join(sysroot, 'lib', target)

	importPaths = describe(config, '--import-paths')
	sources = describe(config, '--data=source-files', '--data-list')
	# dub lists only libdiagnose's own modules; libfp must be compiled in too, or it would not link.
	for path in importPaths:
		if os.path.commonpath([root, os.path.abspath(path)]) != root:
			sources += sorted(glob.glob(os.path.join(path, '**', '*.d'), recursive=True))
	compile = [compiler, '-mtriple=wasm32-unknown-wasi', '-betterC', '-checkaction=C', *flags,
		*('-I' + p for p in importPaths), '-od=' + out, *sources]
	# The long-double archive replaces libc's printf, so it must come first; D's `real` is a 128-bit long double here.
	linkArgs = [os.path.join(libs, 'crt1-command.o'), '-L' + libs, '-lc-printscan-long-double', '-lc', builtins]

	linker = os.environ.get('WASM_LD') or shutil.which('wasm-ld')
	if linker:
		obj = os.path.splitext(wasm)[0] + '.o'
		subprocess.run([*compile, '-c', '-of=' + obj], cwd=root, check=True)
		subprocess.run([linker, '-o', wasm, *linkArgs, obj], cwd=root, check=True)
	else:
		subprocess.run([*compile, '--link-internally', '-of=' + wasm, *('-L' + a for a in linkArgs)], cwd=root, check=True)


def build():
	os.makedirs(out, exist_ok=True)
	# Debug, like `dub test`.
	link('unittest', tests, ['-unittest', '-d-debug'])
	link('example', example, [])

	for f in os.listdir(page):
		shutil.copy(os.path.join(page, f), out)
	install()


def install():
	"""Installs the WASI packages beside the page scripts, which import them by relative path in the browser and Node alike."""
	if not all(os.path.isdir(os.path.join(out, 'node_modules', *p.rpartition('@')[0].split('/'))) for p in packages):
		subprocess.run(['npm', 'install', '--no-save', '--no-package-lock', '--prefix', out, *packages],
			check=True, shell=os.name == 'nt')


class IsolatedHandler(http.server.SimpleHTTPRequestHandler):
	"""Serves with the headers that make a page cross-origin isolated, without which a browser offers no shared memory."""
	def end_headers(self):
		self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
		self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
		super().end_headers()


def serve(port):
	handler = functools.partial(IsolatedHandler, directory=out)
	with http.server.ThreadingHTTPServer(('localhost', port), handler) as server:
		print(f'open http://localhost:{port}/ to run the tests (Ctrl+C stops the server)', file=sys.stderr)
		try:
			server.serve_forever()
		except KeyboardInterrupt:
			pass


def runNode():
	return subprocess.run(['node', os.path.join(out, 'node.mjs'), tests, example]).returncode


def main():
	parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
	mode = parser.add_mutually_exclusive_group()
	mode.add_argument('--serve', nargs='?', const=8000, type=int, metavar='PORT', help='serve the test page for a browser')
	mode.add_argument('--node', action='store_true', help='run the tests and the example under Node')
	args = parser.parse_args()

	build()
	if args.serve:
		serve(args.serve)
	elif args.node:
		sys.exit(runNode())


if __name__ == '__main__':
	main()
