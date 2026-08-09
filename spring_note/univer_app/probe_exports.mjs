import * as s from '@univerjs/sheets';
import * as su from '@univerjs/sheets-ui';
import * as f from '@univerjs/sheets-formula';
import * as fu from '@univerjs/sheets-formula-ui';
console.log('sheets:', Object.keys(s).filter(k=>/Plugin/.test(k)).join(', '));
console.log('sheets-ui:', Object.keys(su).filter(k=>/Plugin/.test(k)).join(', '));
console.log('formula:', Object.keys(f).filter(k=>/Plugin/.test(k)).join(', '));
console.log('formula-ui:', Object.keys(fu).filter(k=>/Plugin/.test(k)).join(', '));
