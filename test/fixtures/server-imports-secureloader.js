// Entry that must fail to bundle for server (node) platform.
import { loadSecure } from '../../src/FinVM/FFI/SecureLoader.js';
void loadSecure;
