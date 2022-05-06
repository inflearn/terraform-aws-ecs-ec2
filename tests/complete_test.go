package main

import (
	"github.com/gruntwork-io/terratest/modules/test-structure"
	"testing"
)

func TestEcsEc2(t *testing.T) {
	t.Parallel()

	ecsTfDir := "../examples/complete"

	defer test_structure.RunTestStage(t, "teardown", func() { teardown(t, ecsTfDir) })
	test_structure.RunTestStage(t, "deploy", func() { deploy(t, ecsTfDir, map[string]interface{}{}) })
}
