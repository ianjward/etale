#!/usr/bin/env node
// The command line: node bin/etale.mjs COMMAND ...  (see README.md)
import { main } from '../engine/etale.mjs';
process.exit(main(process.argv.slice(2)));
