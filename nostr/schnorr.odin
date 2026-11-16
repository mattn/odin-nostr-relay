package nostr

import "core:c"

// BIP-340 Schnorr signature verification through libsecp256k1.

foreign import secp256k1 "system:secp256k1"

@(private)
Secp_Context :: distinct rawptr

@(private)
Xonly_Pubkey :: struct {
	data: [64]u8,
}

@(private)
SECP256K1_CONTEXT_NONE :: 1

@(default_calling_convention = "c", private)
foreign secp256k1 {
	secp256k1_context_create :: proc(flags: c.uint) -> Secp_Context ---
	secp256k1_xonly_pubkey_parse :: proc(ctx: Secp_Context, pubkey: ^Xonly_Pubkey, input32: [^]u8) -> c.int ---
	secp256k1_schnorrsig_verify :: proc(ctx: Secp_Context, sig64: [^]u8, msg: [^]u8, msglen: c.size_t, pubkey: ^Xonly_Pubkey) -> c.int ---
}

// Verification only reads the context, so one context is shared by every
// thread.
@(private)
secp_ctx: Secp_Context

@(init, private)
init_secp :: proc "contextless" () {
	secp_ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE)
}

// Verify a BIP-340 signature over `msg` (the 32-byte event id for Nostr).
schnorr_verify :: proc(pubkey: [32]u8, msg: []u8, sig: [64]u8) -> bool {
	pubkey, sig := pubkey, sig
	pk: Xonly_Pubkey
	if secp256k1_xonly_pubkey_parse(secp_ctx, &pk, &pubkey[0]) != 1 {
		return false
	}
	return secp256k1_schnorrsig_verify(secp_ctx, &sig[0], raw_data(msg), c.size_t(len(msg)), &pk) == 1
}
