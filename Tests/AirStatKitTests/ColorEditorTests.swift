import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

@Suite("The colour picker's arithmetic")
struct ColorEditorTests {

    private func expectClose(_ a: ThemeColor, _ b: ThemeColor,
                             tolerance: Double = 1.0 / 512,
                             _ comment: Comment? = nil) {
        #expect(abs(a.red - b.red) < tolerance, comment)
        #expect(abs(a.green - b.green) < tolerance, comment)
        #expect(abs(a.blue - b.blue) < tolerance, comment)
    }

    @Test("every corner of the colour space survives the round trip")
    func roundTrip() {
        let colors: [ThemeColor] = [
            ThemeColor(red: 1, green: 0, blue: 0),
            ThemeColor(red: 0, green: 1, blue: 0),
            ThemeColor(red: 0, green: 0, blue: 1),
            ThemeColor(red: 1, green: 1, blue: 0),
            ThemeColor(red: 0, green: 1, blue: 1),
            ThemeColor(red: 1, green: 0, blue: 1),
            ThemeColor(red: 0, green: 0, blue: 0),
            ThemeColor(red: 1, green: 1, blue: 1),
            ThemeColor(red: 0.5, green: 0.5, blue: 0.5),
            ThemeColor(red: 0.0, green: 0.53, blue: 1.0),
            ThemeColor(red: 0.13, green: 0.27, blue: 0.42),
        ]
        for color in colors {
            expectClose(HSB(color).themeColor, color, "\(color.hexString)")
        }
    }

    /// The reason the picker holds HSB rather than reading the stored triple back on
    /// every frame: taking a colour to black and returning must return it to the hue
    /// it started on, not to red.
    @Test("brightness can be taken to zero and back without losing the hue")
    func hueSurvivesBlack() {
        var hsb = HSB(ThemeColor(red: 0, green: 0.53, blue: 1))
        let hue = hsb.hue
        hsb.brightness = 0
        #expect(hsb.themeColor == ThemeColor(red: 0, green: 0, blue: 0))
        hsb.brightness = 1
        #expect(hsb.hue == hue)
        expectClose(hsb.themeColor, ThemeColor(red: 0, green: 0.53, blue: 1))
    }

    @Test("saturation can be taken to zero and back without losing the hue")
    func hueSurvivesGrey() {
        var hsb = HSB(ThemeColor(red: 1, green: 0.5, blue: 0))
        let hue = hsb.hue
        hsb.saturation = 0
        #expect(hsb.themeColor.red == hsb.themeColor.blue)
        hsb.saturation = 1
        #expect(hsb.hue == hue)
    }

    @Test("values outside the unit range are clamped rather than wrapped")
    func clamping() {
        let hsb = HSB(hue: 4, saturation: -1, brightness: 12)
        #expect(hsb.hue == 1)
        #expect(hsb.saturation == 0)
        #expect(hsb.brightness == 1)
    }

    @Test("matching is a tolerance, not an equality")
    func matching() {
        let blue = ThemeColor(red: 0, green: 0.53, blue: 1)
        #expect(HSB(blue).matches(blue))
        #expect(!HSB(blue).matches(ThemeColor(red: 0, green: 0.6, blue: 1)))
        // A drift smaller than a step of an 8-bit channel is the same colour.
        #expect(HSB(blue).matches(ThemeColor(red: 0, green: 0.5305, blue: 1)))
    }

    @Test("hex is written the way it is read")
    func hexRoundTrip() {
        let color = ThemeColor(red: 0, green: 0.53, blue: 1)
        #expect(color.hexString == "#0087FF")
        expectClose(ThemeColor(hex: color.hexString)!, color)
    }

    @Test("hex accepts what people actually paste")
    func hexParsing() {
        let red = ThemeColor(red: 1, green: 0, blue: 0)
        for text in ["#FF0000", "ff0000", "  #Ff0000 ", "#F00", "f00"] {
            #expect(ThemeColor(hex: text) == red, "\(text)")
        }
    }

    @Test("a value that is not a colour is refused rather than guessed at")
    func hexRejection() {
        for text in ["", "#", "#F", "#FFFF", "#GGGGGG", "0x00FF00", "rgb(1,2,3)",
                     "#FF00000", "  ", "#FF 00 00"] {
            #expect(ThemeColor(hex: text) == nil, "\(text)")
        }
    }
}
