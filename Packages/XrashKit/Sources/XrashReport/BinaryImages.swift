/// The one lookup every decoder and renderer needs, written once so the bounds
/// check cannot be forgotten in the next one.
extension [BinaryImage] {
    /// The image a frame names — nil when it names none, or names one the
    /// report never listed, which a truncated file does.
    func image(for frame: Frame) -> BinaryImage? {
        frame.imageIndex.flatMap { indices.contains($0) ? self[$0] : nil }
    }

    /// The image whose mapped range holds `address` — nil when none does.
    /// A zero-sized image has no range and never matches. Public because the
    /// app asks it too: a thread sampled without a stack is a bare program
    /// counter, and naming the image it fell in is this same lookup.
    public func index(containing address: UInt64) -> Int? {
        firstIndex { address >= $0.base && $0.size > 0 && address - $0.base < $0.size }
    }
}
