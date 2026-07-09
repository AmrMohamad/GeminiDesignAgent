import XCTest
@testable import GeminiDesignAgentCore

final class DecodingDefaultsTests: XCTestCase {
    func testDesignAnalysisDecodesWhenGeneratedConfidenceFieldsAreOmitted() throws {
        let json = """
        {
          "schemaVersion": "1.0",
          "summary": "A compact login screen",
          "tokens": {
            "colors": [
              { "name": "primary", "hex": "#3366FF", "role": "button" }
            ],
            "typography": [
              { "name": "body", "fontSizePx": 16, "fontWeight": "regular" }
            ],
            "spacingScalePx": [4, 8, 16],
            "radiiPx": [8],
            "shadows": []
          },
          "elements": [
            {
              "id": "el_1",
              "type": "button",
              "label": "Continue",
              "bbox1000": { "ymin": 100, "xmin": 100, "ymax": 200, "xmax": 500 },
              "colorsHex": ["#3366FF"],
              "typography": { "fontSizePx": 16, "fontWeight": "semibold" },
              "spacing": { "top": 8, "right": 16, "bottom": 8, "left": 16 },
              "cssHints": {},
              "children": [],
              "implementationNotes": []
            }
          ],
          "hierarchy": [],
          "components": [
            { "id": "cmp_1", "name": "PrimaryButton", "type": "button", "description": "Main CTA", "elementIds": ["el_1"], "styleHints": {} }
          ],
          "accessibility": [],
          "warnings": [],
          "memoryWrites": [
            { "type": "component", "scope": "global", "priority": 5, "content": "Use PrimaryButton for CTAs.", "tags": ["button"] }
          ]
        }
        """

        let analysis = try JSON.decoder.decode(DesignAnalysis.self, from: Data(json.utf8))

        XCTAssertEqual(analysis.elements[0].bbox1000.confidence, 0.7)
        XCTAssertEqual(analysis.elements[0].typography?.confidence, 0.7)
        XCTAssertEqual(analysis.elements[0].spacing?.confidence, 0.7)
        XCTAssertEqual(analysis.tokens.colors[0].confidence, 0.7)
        XCTAssertEqual(analysis.tokens.typography[0].confidence, 0.7)
        XCTAssertEqual(analysis.components[0].confidence, 0.7)
        XCTAssertEqual(analysis.memoryWrites[0].confidence, 0.7)
    }

    func testPersistedMemoryAtomDefaultsMissingConfidenceToOne() throws {
        let json = """
        {
          "id": "mem_1",
          "projectId": "proj_1",
          "type": "component",
          "scope": "global",
          "priority": 3,
          "content": "Use compact controls.",
          "tags": [],
          "sourceEvidenceIds": [],
          "validFrom": "2026-07-09T00:00:00Z",
          "createdAt": "2026-07-09T00:00:00Z",
          "updatedAt": "2026-07-09T00:00:00Z"
        }
        """

        let atom = try JSON.decoder.decode(MemoryAtom.self, from: Data(json.utf8))

        XCTAssertEqual(atom.confidence, 1.0)
    }
}
