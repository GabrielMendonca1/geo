import Foundation

enum MacDuoAttribution {
    static let upstreamName = "Mac Duo"
    static let upstreamVersion = "0.1.6"
    static let upstreamRepository = "https://github.com/DhananjayBhosale/MacDuo"
    static let copyright = "Copyright (c) 2026 Mac Duo contributors"

    static let license = """
    MIT License

    Copyright (c) 2026 Mac Duo contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """

    static let sensorCredit = """
    The lid angle reader follows the HID identifiers documented by Sam Henri Gold
    in LidAngleSensor (Apache License 2.0): usage page 0x20, usage 0x8A, feature
    report id 1, two-byte little-endian degrees. No code or asset from that
    project is bundled.
    """

    static var summary: String {
        "\(upstreamName) \(upstreamVersion) — MIT — \(upstreamRepository)"
    }
}
