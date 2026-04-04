package ml

import "testing"

func TestFlashAttentionSupportedSYCL(t *testing.T) {
	if !FlashAttentionSupported([]DeviceInfo{{DeviceID: DeviceID{Library: "SYCL"}}}) {
		t.Fatal("expected SYCL devices to be treated as flash-attention-capable")
	}
}
