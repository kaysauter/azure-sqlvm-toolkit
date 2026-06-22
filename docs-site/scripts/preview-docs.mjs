import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const base = '/azure-sqlvm-toolkit';
const root = resolve(fileURLToPath(new URL('../dist', import.meta.url)));

const args = process.argv.slice(2);
const readOption = (name, fallback) => {
	const index = args.findIndex((arg) => arg === name || arg.startsWith(`${name}=`));
	if (index < 0) return fallback;
	const value = args[index].includes('=') ? args[index].split('=').slice(1).join('=') : args[index + 1];
	return value || fallback;
};

const host = readOption('--host', process.env.HOST || '127.0.0.1');
const requestedPort = Number(readOption('--port', readOption('-p', process.env.PORT || '4321')));
let port = requestedPort;

const contentTypes = new Map([
	['.css', 'text/css; charset=utf-8'],
	['.html', 'text/html; charset=utf-8'],
	['.ico', 'image/x-icon'],
	['.js', 'text/javascript; charset=utf-8'],
	['.json', 'application/json; charset=utf-8'],
	['.png', 'image/png'],
	['.svg', 'image/svg+xml'],
	['.wasm', 'application/wasm'],
	['.xml', 'application/xml; charset=utf-8'],
]);

if (!existsSync(root)) {
	console.error("Preview output was not found. Run 'npm run build' before 'npm run preview'.");
	process.exit(1);
}

const send = (res, status, headers, body = '') => {
	res.writeHead(status, headers);
	res.end(body);
};

const resolveFile = (requestPath) => {
	const cleanPath = decodeURIComponent(requestPath.split('?')[0]);
	const withoutBase = cleanPath.startsWith(`${base}/`)
		? cleanPath.slice(base.length + 1)
		: cleanPath.slice(1);
	const candidate = normalize(join(root, withoutBase));

	if (!candidate.startsWith(`${root}${sep}`) && candidate !== root) {
		return null;
	}

	if (existsSync(candidate) && statSync(candidate).isFile()) {
		return candidate;
	}

	const index = join(candidate, 'index.html');
	if (existsSync(index) && statSync(index).isFile()) {
		return index;
	}

	return null;
};

const server = createServer((req, res) => {
	const url = req.url || '/';

	if (url === '/' || url === '') {
		send(res, 302, { Location: `${base}/` });
		return;
	}

	if (url === base) {
		send(res, 302, { Location: `${base}/` });
		return;
	}

	if (!url.startsWith(`${base}/`)) {
		send(res, 404, { 'Content-Type': 'text/plain; charset=utf-8' }, 'Not found');
		return;
	}

	const file = resolveFile(url);
	if (!file) {
		const notFound = join(root, '404.html');
		if (existsSync(notFound)) {
			res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
			if (req.method === 'HEAD') {
				res.end();
				return;
			}
			createReadStream(notFound).pipe(res);
			return;
		}

		send(res, 404, { 'Content-Type': 'text/plain; charset=utf-8' }, 'Not found');
		return;
	}

	const type = contentTypes.get(extname(file)) || 'application/octet-stream';
	res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-cache' });
	if (req.method === 'HEAD') {
		res.end();
		return;
	}
	createReadStream(file).pipe(res);
});

server.on('error', (error) => {
	if (error.code === 'EADDRINUSE' && port < requestedPort + 20) {
		console.warn(`Port ${port} is already in use, trying ${port + 1}...`);
		port += 1;
		server.listen(port, host);
		return;
	}

	if (error.code === 'EPERM' || error.code === 'EACCES') {
		console.error(`Cannot start docs preview on ${host}:${port}. Try another host or port.`);
		process.exit(1);
	}

	console.error(error);
	process.exit(1);
});

server.listen(port, host, () => {
	console.log(`Docs preview ready at http://${host}:${port}${base}/`);
	console.log(`Root URL redirects to ${base}/ for IDE preview panes.`);
});
