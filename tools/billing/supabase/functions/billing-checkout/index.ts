import { checkout, live } from '../_shared/core.ts';

Deno.serve(checkout(live()));
