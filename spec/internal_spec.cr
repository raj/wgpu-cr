require "./spec_helper"

describe WGPU::Internal do
  it "is the single implementation behind the public WGPU helpers" do
    str = "delegation"
    WGPU.view_to_s(WGPU.string_view(str)).should eq(WGPU::Internal.view_to_s(WGPU::Internal.string_view(str)))
    WGPU.null_string_view.length.should eq(WGPU::Internal.null_string_view.length)
    WGPU.empty_string_view.length.should eq(0)
    WGPU.null(LibWGPU::Buffer).null?.should be_true

    # Backward-compatible aliases point at the very same objects.
    WGPU::PENDING_TIMEOUT_RESULTS.should be(WGPU::Internal::PENDING_TIMEOUT_RESULTS)
    WGPU::PENDING_TIMEOUT_MUTEX.should be(WGPU::Internal::PENDING_TIMEOUT_MUTEX)
  end

  it "builds label views (bytes for a String, empty for nil)" do
    label = "my label"
    WGPU::Internal.view_to_s(WGPU::Internal.label_view(label)).should eq("my label")

    empty = WGPU::Internal.label_view(nil)
    empty.data.null?.should be_true
    empty.length.should eq(0)
  end

  it "returns as soon as the condition holds" do
    WGPU.create_instance do |instance|
      calls = 0
      WGPU::Internal.wait_until(instance) { (calls += 1) >= 3 }
      calls.should eq(3)
    end
  end

  it "raises WGPU::Error on timeout and retains the pending result box" do
    WGPU.create_instance do |instance|
      box = Pointer(UInt8).malloc(1).as(Void*)
      expect_raises(WGPU::Error, /timed out/) do
        WGPU::Internal.wait_until(instance, box, 10.milliseconds) { false }
      end
      WGPU::Internal::PENDING_TIMEOUT_RESULTS.should contain(box)

      # A null keep_alive is never retained.
      size = WGPU::Internal::PENDING_TIMEOUT_RESULTS.size
      expect_raises(WGPU::Error) do
        WGPU::Internal.wait_until(instance, timeout: 10.milliseconds) { false }
      end
      WGPU::Internal::PENDING_TIMEOUT_RESULTS.size.should eq(size)
    end
  end
end
