//
//  Aagedal_VideoLoop_Converter_2_0Tests.swift
//  Aagedal VideoLoop Converter 2.0Tests
//
//  Created by Truls Aagedal on 30/06/2024.
//

import XCTest
@testable import Aagedal_Media_Converter

final class Aagedal_Media_Converter_Tests: XCTestCase {

    func testCropInsertedBeforeDarDesqueezeForAnamorphicSources() throws {
        // This mirrors the built-in preset filter chain used by TV-HD / ProRes:
        // 1) Normalize DAR into square pixels (desqueeze)
        // 2) Final scaling to target size
        var args: [String] = [
            "-vf",
            "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"
        ]

        // MXF test case: 1440x1080 with SAR 4:3 (DAR 16:9)
        // A 1:1 crop in DISPLAY space corresponds to keeping full height (1080) and cropping width to 1080 in display.
        // Display width is 1440 * 4/3 = 1920, so normalized width = 1080/1920.
        let cropWidth = 1080.0 / 1920.0
        let cropX = (1.0 - cropWidth) / 2.0

        let cropConfig = CropConfig(
            normalizedRect: CropRect(x: cropX, y: 0, width: cropWidth, height: 1)
        )

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: cropConfig,
            sourceWidth: 1440,
            sourceHeight: 1080,
            pixelAspectRatio: 4.0 / 3.0
        )

        let vfIndex = try XCTUnwrap(args.firstIndex(of: "-vf"))
        let filterChain = args[vfIndex + 1]

        let cropRange = try XCTUnwrap(filterChain.range(of: "crop="))
        let desqueezeRange = try XCTUnwrap(filterChain.range(of: "scale='trunc(ih*dar"))

        // Crop must be applied BEFORE the DAR-based desqueeze step.
        XCTAssertLessThan(cropRange.lowerBound, desqueezeRange.lowerBound)

        // The preset already normalizes to square pixels; avoid a second desqueeze stage.
        XCTAssertFalse(filterChain.contains("scale=1080:1080,setsar=1"))
    }

}
