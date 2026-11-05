import { webhook, live } from '../_shared/core.ts';

Deno.serve(webhook(live()));
