// SPDX-License-Identifier: BSD-3-Clause

//go:build linux

// This file is not part of Tailscale. The GL.iNet build copies it into the Tailscale
// source tree as util/linuxfw/zz_gl_invariants_test.go (see
// scripts/apply-tailscale-patches.sh and .github/workflows/build-tailscale.yaml) and
// asserts the end state that patches/ is supposed to produce.
//
// It deliberately checks the compiled values rather than patch(1) exit codes. A hunk
// that was silently skipped, or that applied in the wrong place, cannot fool it -- and
// it keeps passing once Tailscale implements the same behaviour itself, which is
// exactly the point at which the corresponding patch should be retired.

package linuxfw

import (
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/google/nftables/expr"
	"tailscale.com/tsconst"
)

func TestGLPatchInvariants(t *testing.T) {
	t.Run("FwmarkBytesAreNativeEndian", testGLFwmarkBytesAreNativeEndian)
	t.Run("ConnmarkRestoreCopiesFullCtMark", testGLConnmarkRestoreCopiesFullCtMark)
}

// testGLFwmarkBytesAreNativeEndian guards the end state of the retired
// patches/0001-fix-nftables-fwmark-endianness.patch. Tailscale fixed this itself in
// v1.100.0 (tailscale/tailscale#11803); before that the mask bytes were hardcoded
// big-endian, which was accidentally right on mips/mips64 and wrong everywhere else.
func testGLFwmarkBytesAreNativeEndian(t *testing.T) {
	if got, want := uint32(tsconst.LinuxFwmarkMaskNum), uint32(0x00ff0000); got != want {
		t.Errorf("tsconst.LinuxFwmarkMaskNum = %#08x, want %#08x", got, want)
	}
	if got, want := uint32(tsconst.LinuxSubnetRouteMarkNum), uint32(0x00040000); got != want {
		t.Errorf("tsconst.LinuxSubnetRouteMarkNum = %#08x, want %#08x", got, want)
	}

	for _, tt := range []struct {
		name string
		got  []byte
		want uint32
	}{
		{"getTailscaleFwmarkMask", getTailscaleFwmarkMask(), uint32(tsconst.LinuxFwmarkMaskNum)},
		{"getTailscaleFwmarkMaskNeg", getTailscaleFwmarkMaskNeg(), ^uint32(tsconst.LinuxFwmarkMaskNum)},
		{"getTailscaleSubnetRouteMark", getTailscaleSubnetRouteMark(), uint32(tsconst.LinuxSubnetRouteMarkNum)},
	} {
		want := binary.NativeEndian.AppendUint32(nil, tt.want)
		if !bytes.Equal(tt.got, want) {
			t.Errorf("%s() = % x, want % x (native-endian %#08x); tailscale/tailscale#11803 regressed, "+
				"restore patches/0001-fix-nftables-fwmark-endianness.patch", tt.name, tt.got, want, tt.want)
		}
	}
}

// testGLConnmarkRestoreCopiesFullCtMark guards the end state of
// patches/0002-nft-connmark-restore-gl-coexist.patch: the PREROUTING restore rule must
// write the *unmasked* ct mark to the skb, so vendor bits (GL policy routing 0x8000)
// survive instead of being masked away. Upstream masks to the Tailscale band.
func testGLConnmarkRestoreCopiesFullCtMark(t *testing.T) {
	exprs := makeConnmarkRestoreExprs()
	if len(exprs) < 2 {
		t.Fatalf("makeConnmarkRestoreExprs() returned %d expressions, want at least 2", len(exprs))
	}

	meta, ok := exprs[len(exprs)-1].(*expr.Meta)
	if !ok {
		t.Fatalf("last expression is %T, want *expr.Meta", exprs[len(exprs)-1])
	}
	if meta.Key != expr.MetaKeyMARK || !meta.SourceRegister {
		t.Fatalf("last expression = %+v, want Key=MetaKeyMARK with SourceRegister set", meta)
	}

	ct, ok := exprs[len(exprs)-2].(*expr.Ct)
	if !ok {
		t.Fatalf("expression before the meta-mark assignment is %T, want *expr.Ct reloading the "+
			"unmasked ct mark; patches/0002-nft-connmark-restore-gl-coexist.patch did not take effect",
			exprs[len(exprs)-2])
	}
	if ct.Key != expr.CtKeyMARK {
		t.Fatalf("expression before the meta-mark assignment loads ct key %v, want CtKeyMARK", ct.Key)
	}
	if ct.Register != meta.Register {
		t.Fatalf("ct reload writes register %d but the meta-mark assignment reads register %d",
			ct.Register, meta.Register)
	}

	var ctMarkLoads int
	for _, e := range exprs {
		if c, ok := e.(*expr.Ct); ok && c.Key == expr.CtKeyMARK {
			ctMarkLoads++
		}
	}
	if ctMarkLoads != 2 {
		t.Errorf("makeConnmarkRestoreExprs() loads the ct mark %d time(s), want 2: once masked for "+
			"the non-zero guard, once unmasked for the skb mark", ctMarkLoads)
	}
}
