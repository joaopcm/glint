public enum TallCapture {
    // iPhone screenshots run 2556/1179 ≈ 2.17 tall-to-wide and still read fine fit whole in the card; scrolling captures run well past 3.
    static let heightPerWidth = 3

    public static func isTall(width: Int, height: Int) -> Bool {
        height > heightPerWidth * width
    }
}
