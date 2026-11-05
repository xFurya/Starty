import { refund, live } from '../_shared/core.ts';

Deno.serve(refund(live()));
