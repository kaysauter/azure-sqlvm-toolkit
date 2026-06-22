import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const deckBase = '/azure-sqlvm-toolkit/pitch/deck/';
const assetsRoot = resolve(fileURLToPath(new URL('../dist/pitch/deck/assets', import.meta.url)));

const routeHelperPattern = new RegExp(
	`return\`${deckBase.replaceAll('/', '\\/')}` +
		'\\$\\{([A-Za-z_$][\\w$]*)\\?`export/\\$\\{([A-Za-z_$][\\w$]*)\\}`:' +
		'([A-Za-z_$][\\w$]*)\\?`presenter/\\$\\{\\2\\}`:`\\$\\{\\2\\}`\\}`',
	'g',
);

const patchedRouteHelperPattern = new RegExp(
	'return`\\/\\$\\{([A-Za-z_$][\\w$]*)\\?`export/\\$\\{([A-Za-z_$][\\w$]*)\\}`:' +
		'([A-Za-z_$][\\w$]*)\\?`presenter/\\$\\{\\2\\}`:`\\$\\{\\2\\}`\\}`',
	'g',
);
const historyBasePattern = new RegExp(
	`history:([A-Za-z_$][\\w$]*)\\("${deckBase.replaceAll('/', '\\/')}"\\)`,
	'g',
);
const patchedHistoryBasePattern = new RegExp(
	`history:([A-Za-z_$][\\w$]*)\\("${deckBase.replaceAll('/', '\\/')}#"\\)`,
	'g',
);

const findJavaScriptFiles = (directory) => {
	const entries = readdirSync(directory, { withFileTypes: true });
	const files = [];

	for (const entry of entries) {
		const path = join(directory, entry.name);
		if (entry.isDirectory()) {
			files.push(...findJavaScriptFiles(path));
			continue;
		}

		if (entry.isFile() && entry.name.endsWith('.js')) {
			files.push(path);
		}
	}

	return files;
};

if (!existsSync(assetsRoot)) {
	console.error(`Slidev assets directory was not found: ${assetsRoot}`);
	process.exit(1);
}

let replacements = 0;
let alreadyPatched = 0;

for (const file of findJavaScriptFiles(assetsRoot)) {
	const source = readFileSync(file, 'utf8');
	alreadyPatched += source.match(patchedRouteHelperPattern)?.length || 0;
	alreadyPatched += source.match(patchedHistoryBasePattern)?.length || 0;
	let patched = source.replace(routeHelperPattern, (_match, exportFlag, routeValue, presenterFlag) => {
		replacements += 1;
		return `return\`/\${${exportFlag}?\`export/\${${routeValue}}\`:${presenterFlag}?\`presenter/\${${routeValue}}\`:\`\${${routeValue}}\`}\``;
	});
	patched = patched.replace(historyBasePattern, (_match, historyHelper) => {
		replacements += 1;
		return `history:${historyHelper}("${deckBase}#")`;
	});

	if (patched !== source) {
		writeFileSync(file, patched);
	}
}

if (replacements === 1) {
	console.log('Patched Slidev routing to use hash-safe GitHub Pages paths.');
	process.exit(0);
}

if (replacements === 0 && alreadyPatched === 1) {
	console.log('Slidev routing already uses hash-safe GitHub Pages paths.');
	process.exit(0);
}

if (replacements === 0) {
	console.error('Could not find the Slidev route helper to patch.');
	process.exit(1);
}

console.error(`Expected to patch exactly one Slidev route helper, but patched ${replacements}.`);
process.exit(1);
