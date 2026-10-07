/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

'use strict';

// editWin32Resources(file, patch): edits the version and icon resources of a
// Windows PE file, with rcedit's options:
//   { 'version-string': { Key: value, ... }, 'file-version': string,
//     'product-version': string, icon: path-to-.ico }
//
// On a Windows host this is rcedit, as upstream. rcedit is a Windows
// executable (bin/rcedit.exe, i386; lib/rcedit.js runs it under `wine` on other
// hosts), so on other hosts the same edit is done in JavaScript with resedit:
// a file without a version resource gets one (language 1033, codepage 1200,
// VFT_APP); version strings are set in every string table;
// 'file-version'/'product-version' set the fixed version and the FileVersion/
// ProductVersion string; 'icon' replaces the icons of the first icon group.
// The Authenticode signature, which an edit invalidates, is dropped.

const fs = require('fs');
const { promisify } = require('util');

function parseVersion(version) {
	const parts = version.split('.').map(n => parseInt(n, 10) || 0);
	while (parts.length < 4) {
		parts.push(0);
	}
	return { ms: ((parts[0] << 16) | parts[1]) >>> 0, ls: ((parts[2] << 16) | parts[3]) >>> 0 };
}

const SUPPORTED_OPTIONS = ['version-string', 'file-version', 'product-version', 'icon'];

function patchWin32Resources(file, patch) {
	const unsupported = Object.keys(patch).filter(option => !SUPPORTED_OPTIONS.includes(option));
	if (unsupported.length) {
		throw new Error(`win32Resources: rcedit option(s) not implemented off Windows: ${unsupported.join(', ')}`);
	}
	const ResEdit = require('resedit');
	const exe = ResEdit.NtExecutable.from(fs.readFileSync(file), { ignoreCert: true });
	const res = ResEdit.NtExecutableResource.from(exe);

	// As rcedit (src/rescle.cc): only the version resource of the lowest
	// language id is edited (one in language 1033 is created if there is none);
	// a string is replaced in the first string table that has it, otherwise
	// appended to every string table.
	if (patch['version-string'] || patch['file-version'] || patch['product-version']) {
		const infos = ResEdit.Resource.VersionInfo.fromEntries(res.entries).sort((a, b) => a.lang - b.lang);
		let info = infos[0];
		if (!info) {
			info = ResEdit.Resource.VersionInfo.createEmpty();
			info.lang = 1033;
			info.fixedInfo.fileType = 1; // VFT_APP
		}
		let tables = info.getAllLanguagesForStringValues();
		if (tables.length === 0) {
			tables = [{ lang: 1033, codepage: 1200 }];
		}
		const setString = (name, value) => {
			const table = tables.find(t => info.getStringValues(t)[name] !== undefined);
			for (const t of table ? [table] : tables) {
				info.setStringValue(t, name, value);
			}
		};
		for (const [name, value] of Object.entries(patch['version-string'] || {})) {
			setString(name, value);
		}
		if (patch['file-version']) {
			const v = parseVersion(patch['file-version']);
			info.fixedInfo.fileVersionMS = v.ms;
			info.fixedInfo.fileVersionLS = v.ls;
			setString('FileVersion', patch['file-version']);
		}
		if (patch['product-version']) {
			const v = parseVersion(patch['product-version']);
			info.fixedInfo.productVersionMS = v.ms;
			info.fixedInfo.productVersionLS = v.ls;
			setString('ProductVersion', patch['product-version']);
		}
		info.outputToResourceEntries(res.entries);
	}

	if (patch.icon) {
		const iconFile = ResEdit.Data.IconFile.from(fs.readFileSync(patch.icon));
		// As rcedit: the icon group with the lowest id in the lowest language,
		// or group 1 in language 1033 if there is none.
		const group = ResEdit.Resource.IconGroupEntry.fromEntries(res.entries).sort((a, b) => a.lang - b.lang || a.id - b.id)[0];
		ResEdit.Resource.IconGroupEntry.replaceIconsForResource(
			res.entries, group ? group.id : 1, group ? group.lang : 1033, iconFile.icons.map(icon => icon.data));
	}

	res.outputResource(exe);
	fs.writeFileSync(file, Buffer.from(exe.generate()));
}

async function editWin32Resources(file, patch) {
	if (process.platform === 'win32') {
		return promisify(require('rcedit'))(file, patch);
	}
	patchWin32Resources(file, patch);
}

exports.editWin32Resources = editWin32Resources;
