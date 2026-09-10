// Negative fixture — proves `#Config.image.digest` rejects a non-digest
// reference. `timoni mod vet --values tests/invalid-image-digest.cue` MUST
// fail (constraint violation on the sha256 pattern). A green vet here means
// the digest constraint has been weakened or removed.
//
// Run by `deploy/frontend/scripts/tests/timoni-vet.bats` (expects exit != 0).
package main

values: {
	image: {
		repository: "ghcr.io/insuperposition/cv-frontend"
		tag:        "main"
		// A tag masquerading as a digest — not 64 hex chars, no sha256: shape.
		digest: "latest"
	}
}
