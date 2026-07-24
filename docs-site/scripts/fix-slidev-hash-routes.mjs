import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const deckBase = '/azure-sqlvm-toolkit/pitch/deck/';
const assetsRoot = resolve(fileURLToPath(new URL('../dist/pitch/deck/assets', import.meta.url)));
const indexHtmlPath = resolve(fileURLToPath(new URL('../dist/pitch/deck/index.html', import.meta.url)));
const gotoDialogStyleId = 'slidev-goto-dialog-fix';
const gotoDialogStyle = `<style id="${gotoDialogStyleId}">
#slidev-goto-dialog[class*="-top-20"]{display:none!important}
</style>`;

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
	`history:([A-Za-z_$][\\w$]*)\\((["'\`])${deckBase.replaceAll('/', '\\/')}\\2\\)`,
	'g',
);
const patchedHistoryBasePattern = new RegExp(
	`history:([A-Za-z_$][\\w$]*)\\((["'\`])${deckBase.replaceAll('/', '\\/')}#\\2\\)`,
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

const ensureGotoDialogStyle = () => {
	if (!existsSync(indexHtmlPath)) {
		console.error(`Slidev index.html was not found: ${indexHtmlPath}`);
		process.exit(1);
	}

	const source = readFileSync(indexHtmlPath, 'utf8');
	if (source.includes(`id="${gotoDialogStyleId}"`)) {
		return false;
	}

	if (!source.includes('</head>')) {
		console.error('Could not find </head> in Slidev index.html.');
		process.exit(1);
	}

	writeFileSync(indexHtmlPath, source.replace('</head>', `${gotoDialogStyle}\n</head>`));
	return true;
};

if (!existsSync(assetsRoot)) {
	console.error(`Slidev assets directory was not found: ${assetsRoot}`);
	process.exit(1);
}

let routeReplacements = 0;
let historyReplacements = 0;
let routeAlreadyPatched = 0;
let historyAlreadyPatched = 0;

for (const file of findJavaScriptFiles(assetsRoot)) {
	const source = readFileSync(file, 'utf8');
	routeAlreadyPatched += source.match(patchedRouteHelperPattern)?.length || 0;
	historyAlreadyPatched += source.match(patchedHistoryBasePattern)?.length || 0;
	let patched = source.replace(routeHelperPattern, (_match, exportFlag, routeValue, presenterFlag) => {
		routeReplacements += 1;
		return `return\`/\${${exportFlag}?\`export/\${${routeValue}}\`:${presenterFlag}?\`presenter/\${${routeValue}}\`:\`\${${routeValue}}\`}\``;
	});
	patched = patched.replace(historyBasePattern, (_match, historyHelper) => {
		historyReplacements += 1;
		return `history:${historyHelper}(\`${deckBase}#\`)`;
	});

	if (patched !== source) {
		writeFileSync(file, patched);
	}
}

const routePatchOk = routeReplacements === 1 || (routeReplacements === 0 && routeAlreadyPatched === 1);
const historyPatchOk = historyReplacements === 1 || (historyReplacements === 0 && historyAlreadyPatched === 1);

if (!routePatchOk) {
	console.error(
		`Expected to patch or find exactly one Slidev route helper, but patched ${routeReplacements} and found ${routeAlreadyPatched} already patched.`,
	);
	process.exit(1);
}

if (!historyPatchOk) {
	console.error(
		`Expected to patch or find exactly one Slidev history base, but patched ${historyReplacements} and found ${historyAlreadyPatched} already patched.`,
	);
	process.exit(1);
}

const patchedGotoDialog = ensureGotoDialogStyle();

console.log(
	routeReplacements === 1 || historyReplacements === 1
		? 'Patched Slidev routing to use hash-safe GitHub Pages paths.'
		: 'Slidev routing already uses hash-safe GitHub Pages paths.',
);
console.log(
	patchedGotoDialog
		? 'Patched Slidev goto dialog closed-state visibility.'
		: 'Slidev goto dialog visibility patch already present.',
);
process.exit(0);
