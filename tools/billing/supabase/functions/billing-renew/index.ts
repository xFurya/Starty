import { renew, live } from '../_shared/core.ts';

Deno.serve(renew(live()));
