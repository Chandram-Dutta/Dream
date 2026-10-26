import Foundation
import Testing
@testable import Dream
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// The geometry behind figures and diagrams: fitting, handles, labels and layout. No model involved.

/// A right triangle with squares on its sides.
private let pythagoras: Surface = {
    var surface = Surface.empty
    surface.title = "Pythagoras"
    surface.inputs = [input("a", 3, 1, 8), input("b", 4, 1, 8)]
    surface.outputs = [Output(name: "c", label: "Hypotenuse", formula: "sqrt(a^2 + b^2)", format: .number)]
    surface.figures = [Figure(name: "triangle", points: [
        FigurePoint(name: "C", x: "0", y: "0", label: "C"),
        FigurePoint(name: "B", x: "a", y: "0", label: "B"),
        FigurePoint(name: "A", x: "0", y: "b", label: "A"),
        FigurePoint(name: "P", x: "a", y: "-a", label: ""),
        FigurePoint(name: "Q", x: "0", y: "-a", label: ""),
        FigurePoint(name: "R", x: "-b", y: "b", label: ""),
        FigurePoint(name: "S", x: "-b", y: "0", label: ""),
        FigurePoint(name: "T", x: "B.x + A.y", y: "B.x", label: ""),
        FigurePoint(name: "U", x: "A.y", y: "A.y + B.x", label: ""),
    ], shapes: [
        FigureShape(kind: .polygon, points: ["C", "B", "A"], label: "", tone: .main),
        FigureShape(kind: .polygon, points: ["C", "B", "P", "Q"], label: "$a^2$", tone: .contrast),
        FigureShape(kind: .polygon, points: ["C", "A", "R", "S"], label: "$b^2$", tone: .contrast),
        FigureShape(kind: .polygon, points: ["B", "T", "U", "A"], label: "$c^2$", tone: .main),
        FigureShape(kind: .rightAngle, points: ["B", "C", "A"]),
        FigureShape(kind: .segment, points: ["B", "A"], label: "c = {c}", tone: .main),
    ])]
    return surface
}()

/// A thrown ball: a path, and a launch arrow whose tip sets speed and angle.
private let throwSurface: Surface = {
    var surface = Surface.empty
    surface.title = "Throw"
    surface.inputs = [input("speed", 20, 5, 30, step: 1), input("angle", 45, 5, 85, step: 1), input("g", 9.81, 9.81, 9.81, role: .given)]
    surface.outputs = [
        Output(name: "flightTime", label: "Time in the air", formula: "2 * speed * sin(angle * pi / 180) / g", format: .number),
        Output(name: "range", label: "Distance", formula: "speed^2 * sin(2 * angle * pi / 180) / g", format: .number),
    ]
    var path = FigureShape(kind: .path, over: "t", x: "speed * cos(angle * pi / 180) * t", y: "speed * sin(angle * pi / 180) * t - g * t^2 / 2", tone: .main)
    (path.from, path.to) = ("0", "flightTime")
    surface.figures = [Figure(name: "flight", points: [
        FigurePoint(name: "O", x: "0", y: "0", label: ""),
        FigurePoint(name: "tip", x: "speed * cos(angle * pi / 180) * 0.5", y: "speed * sin(angle * pi / 180) * 0.5", label: ""),
        FigurePoint(name: "land", x: "range", y: "0", label: "{range} m"),
        FigurePoint(name: "end", x: "100", y: "0", label: ""),
    ], shapes: [
        FigureShape(kind: .segment, points: ["O", "end"], tone: .guide),
        path,
        FigureShape(kind: .arrow, points: ["O", "tip"], label: "v", tone: .contrast),
    ])]
    return surface
}()

private func diagram(_ shape: Diagram.Shape, _ labels: [String], edges: [(Int, Int)] = []) -> Diagram {
    let nodes = labels.enumerated().map { Diagram.Node(id: "n\($0.offset)", label: $0.element, detail: "") }
    return Diagram(name: "d", shape: shape, nodes: nodes, edges: edges.map { Diagram.Edge(from: "n\($0.0)", to: "n\($0.1)", label: "") })
}

private func written(_ name: String, _ shape: Diagram.Shape, _ nodes: [(String, String)], _ edges: [(String, String, String)]) -> Diagram {
    Diagram(name: name, shape: shape, nodes: nodes.map { Diagram.Node(id: $0.0, label: $0.1, detail: "") },
            edges: edges.map { Diagram.Edge(from: $0.0, to: $0.1, label: $0.2) })
}

/// Diagrams as Grok wrote them.
private let writtenDiagrams: [Diagram] = [
    // The one that was a tangle on the phone.
    written("waterOnPhone", .cycle, [("evaporation", "Evaporation"), ("condensation", "Condensation"), ("precipitation", "Precipitation"), ("runoff", "Runoff"),
                                     ("ocean", "Ocean"), ("transpiration", "Transpiration"), ("groundwater", "Groundwater")],
            [("ocean", "evaporation", "Sun heats the sea"), ("evaporation", "condensation", "vapour rises"), ("condensation", "precipitation", "clouds form"),
             ("precipitation", "runoff", "rain and snow"), ("runoff", "ocean", "rivers to sea"), ("precipitation", "groundwater", "soaks in"),
             ("groundwater", "ocean", "springs and seepage"), ("transpiration", "condensation", "plants release vapour")]),
    written("water", .cycle, [("ocean", "Ocean"), ("vapor", "Water vapour"), ("clouds", "Clouds"), ("land", "Land"), ("ground", "Groundwater"), ("ice", "Ice and snow")],
            [("ocean", "vapor", "evaporation, transpiration"), ("ice", "vapor", "sublimation"), ("vapor", "clouds", "condensation"), ("clouds", "land", "precipitation"),
             ("clouds", "ocean", "precipitation"), ("land", "ground", "infiltration"), ("land", "ocean", "runoff"), ("ground", "ocean", "subsurface flow"), ("ice", "ocean", "melt")]),
    written("carbon", .cycle, [("air", "Atmosphere"), ("plants", "Plants"), ("life", "Soil and life"), ("ocean", "Ocean"), ("rocks", "Deep rock")],
            [("air", "plants", "photosynthesis"), ("plants", "life", "growth and death"), ("life", "air", "respiration"), ("air", "ocean", "dissolves"),
             ("ocean", "rocks", "burial"), ("life", "rocks", "fossilisation"), ("rocks", "air", "volcanoes and burning")]),
    written("nitrogen", .cycle, [("n2", "Atmospheric N₂"), ("fixation", "Fixation"), ("ammonium", "Ammonium"), ("nitrification", "Nitrification"), ("nitrate", "Nitrate"),
                                 ("organisms", "Living things"), ("ammonification", "Ammonification"), ("denitrification", "Denitrification")],
            [("n2", "fixation", "N₂ to NH₃"), ("fixation", "ammonium", ""), ("ammonium", "nitrification", "to nitrite, then nitrate"), ("nitrification", "nitrate", ""),
             ("nitrate", "organisms", "plants and microbes take it up"), ("organisms", "ammonification", "decay returns nitrogen"), ("ammonification", "ammonium", "back to ammonium"),
             ("nitrate", "denitrification", "nitrate to N₂"), ("denitrification", "n2", "returns to the air")]),
    written("bill", .flow, [("introduce", "First reading"), ("second", "Second reading"), ("third", "Third reading"), ("otherHouse", "Other House"),
                            ("joint", "Joint sitting"), ("assent", "President's assent"), ("act", "The Act")],
            [("introduce", "second", ""), ("second", "third", ""), ("third", "otherHouse", "passed"), ("otherHouse", "joint", "disagree"),
             ("otherHouse", "assent", "agreed"), ("joint", "assent", ""), ("assent", "act", "")]),
    written("photosynthesis", .flow, [("co2", "Carbon dioxide"), ("water", "Water"), ("light", "Light"), ("convert", "Photosynthesis"), ("sugar", "Glucose"), ("oxygen", "Oxygen")],
            [("co2", "convert", "in"), ("water", "convert", "in"), ("light", "convert", "energy"), ("convert", "sugar", "stored"), ("convert", "oxygen", "out")]),
    written("animals", .tree, [("animals", "Animals"), ("vertebrates", "Vertebrates"), ("invertebrates", "Invertebrates")],
            [("animals", "vertebrates", "backbone"), ("animals", "invertebrates", "no backbone")]),
]

/// Text measured with the system font the app uses, at the sizes it uses.
private let measured: DiagramLayout.Metrics = {
    var metrics = DiagramLayout.Metrics.standard
    #if canImport(UIKit)
    metrics.measureNode = { ($0 as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]).width }
    metrics.measureLabel = { ($0 as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 11, weight: .medium)]).width }
    #else
    metrics.measureNode = { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).width }
    metrics.measureLabel = { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width }
    #endif
    return metrics
}()

@Suite("Figures")
struct FiguresTests {
    @Test("Pythagoras: drawing, handles and dragging")
    func pythagorasHandles() throws {
        let figure = try #require(pythagoras.figures?.first)
        let drawing = figure.drawing(in: pythagoras, given: [:])
        #expect(drawing.marks.count == 6, "every Pythagoras shape is drawn")
        #expect(drawing.points["T"] == Vec2(x: 7, y: 3), "points can use other points' coordinates")
        let handles = figure.handles(in: pythagoras)
        #expect(handles.map(\.point) == ["B", "A"], "the legs' corners are the handles")
        #expect(handles.first?.inputs == ["a"], "B sets a")

        // Dragging B along the bottom sets a, snapped to its step.
        let handle = try #require(handles.first)
        let values = figure.dragged(handle, to: Vec2(x: 5.33, y: 0.4), in: pythagoras, given: [:])
        #expect(near(values["a"] ?? 0, 5.3), "dragging B to x 5.33 sets a to 5.3")
        let clamped = figure.dragged(handle, to: Vec2(x: 30, y: 0), in: pythagoras, given: [:])
        #expect(near(clamped["a"] ?? 0, 8), "dragging past the range stops at its end")
    }

    @Test("Pythagoras: the view fits, and labels sit clear")
    func pythagorasLayout() throws {
        let figure = try #require(pythagoras.figures?.first)
        let drawing = figure.drawing(in: pythagoras, given: [:])
        // The view fits the figure as it is, filling the panel but for the margin.
        let start = try #require(drawing.bounds)
        #expect(figure.startBounds(in: pythagoras) == start, "the panel takes the shape of the starting figure")
        let (width, height) = (317.0, 317 * FigureViewport.aspect(of: start))
        let viewport = FigureViewport(fitting: start, width: width, height: height)
        let shown = try #require(Rect2(containing: [viewport.screen(Vec2(x: start.minX, y: start.minY)), viewport.screen(Vec2(x: start.maxX, y: start.maxY))]))
        #expect(shown.width >= width - 2 * FigureViewport.margin - 1 || shown.height >= height - 2 * FigureViewport.margin - 1, "the figure fills its panel")
        let corner = viewport.screen(Vec2(x: 3, y: 4))
        #expect(near(viewport.model(corner).x, 3) && near(viewport.model(corner).y, 4), "screen and figure units convert both ways")
        #expect(viewport.screen(Vec2(x: 0, y: 1)).y < viewport.screen(Vec2(x: 0, y: 0)).y, "y points up")

        // Labels at their real sizes sit clear of each other, of every line and of the right-angle mark.
        let sizes: [Int: Vec2] = Dictionary(uniqueKeysWithValues: drawing.labels.map { label in
            (label.id, Vec2(x: label.text.contains("{") ? 52 : label.text.contains("$") ? 22 : 12, y: 18))
        })
        let placed = drawing.placeLabels(in: viewport, sizes: sizes, bounds: Rect2(minX: 0, minY: 0, maxX: width, maxY: height))
        #expect(placed.count == drawing.labels.count, "every label is placed")
        let boxes = Array(placed.values)
        let overlapping = boxes.indices.flatMap { i in boxes.indices.filter { j in i < j && boxes[i].overlap(boxes[j]) > 1 } }
        #expect(overlapping.isEmpty, "labels don't overlap")
        var lines: [(Vec2, Vec2)] = []
        for mark in drawing.marks {
            switch mark.geometry {
            case .line(let points, let closed):
                let screen = points.map(viewport.screen) + (closed ? [viewport.screen(points[0])] : [])
                lines += zip(screen, screen.dropFirst()).map { ($0, $1) }
            case .angle(let vertex, let a, let b):
                let square = FigureMarks.rightAngle(viewport.screen(vertex), viewport.screen(a), viewport.screen(b), size: 11)
                lines += zip(square, square.dropFirst()).map { ($0, $1) }
            case .text:
                break
            }
        }
        let touching = placed.filter { _, box in lines.contains { box.insetBy(-1).crosses($0.0, $0.1) } }.map(\.key)
        let touchingText = touching.compactMap { id in drawing.labels.first { $0.id == id }?.text }
        #expect(touchingText.isEmpty, "labels sit clear of lines and marks")

        // The checker keeps a good figure as it is.
        var checked = pythagoras
        let issues = Checker.checkFigures(&checked)
        #expect(issues.isEmpty && checked.figures == pythagoras.figures, "a good figure passes unchanged")
    }

    @Test("Squares on the sides go outward, whichever way round the side is named")
    func squaresGoOutward() throws {
        var surface = pythagoras
        surface.figures = [Figure(name: "squares", points: [
            FigurePoint(name: "C", x: "0", y: "0", label: ""),
            FigurePoint(name: "B", x: "a", y: "0", label: ""),
            FigurePoint(name: "A", x: "0", y: "b", label: ""),
        ], shapes: [
            FigureShape(kind: .polygon, points: ["C", "B", "A"], tone: .main),
            FigureShape(kind: .square, points: ["A", "B"], label: "$c^2$"),
            FigureShape(kind: .square, points: ["C", "B"]),
            FigureShape(kind: .square, points: ["A", "C", "B"]),
        ])]
        let marks = try #require(surface.figures?.first).drawing(in: surface, given: [:]).marks
        func corners(_ index: Int) -> [Vec2] {
            if case .line(let points, _) = marks.first(where: { $0.id == index })?.geometry { return points }
            return []
        }
        #expect(Set(corners(1)) == [Vec2(x: 0, y: 4), Vec2(x: 3, y: 0), Vec2(x: 7, y: 3), Vec2(x: 4, y: 7)], "the square on the hypotenuse is outside the triangle")
        #expect(Set(corners(2)) == [Vec2(x: 0, y: 0), Vec2(x: 3, y: 0), Vec2(x: 3, y: -3), Vec2(x: 0, y: -3)], "the square on a is below it")
        #expect(Set(corners(3)) == [Vec2(x: 0, y: 4), Vec2(x: 0, y: 0), Vec2(x: -4, y: 0), Vec2(x: -4, y: 4)], "the square on b is built away from B")
    }

    @Test("A thrown ball: its path lands at the range, and the arrow's tip sets speed and angle")
    func thrownBall() throws {
        let figure = try #require(throwSurface.figures?.first)
        let drawing = figure.drawing(in: throwSurface, given: [:])
        guard case .line(let path, _)? = drawing.marks.first(where: { $0.shape.kind == .path })?.geometry, let last = path.last else {
            Issue.record("the path is drawn")
            return
        }
        #expect(near(last.x, 20 * 20 / 9.81) && near(last.y, 0), "the path lands at the range")
        let handles = figure.handles(in: throwSurface)
        #expect(handles.map(\.point) == ["tip"] && handles.first?.inputs == ["angle", "speed"], "the arrow's tip sets speed and angle")
        let handle = try #require(handles.first)
        // Straight up and 12 long, at the 0.5 scale: speed 24, angle as steep as it goes.
        let started = Date()
        let values = figure.dragged(handle, to: Vec2(x: 6, y: 6 * sqrt(3)), in: throwSurface, given: [:])
        let elapsed = Date().timeIntervalSince(started)
        #expect(near(values["speed"] ?? 0, 24) && near(values["angle"] ?? 0, 60), "dragging the tip sets speed 24 at 60°")
        if isOptimized { #expect(elapsed < 0.02, "a drag step is quick") }
        var checked = throwSurface
        _ = Checker.checkFigures(&checked)
        #expect(checked.figureAxes == ["t"], "the path's t is its own")
    }

    @Test("A point turned all the way round is still a handle, and an angle gets the arms no shape draws")
    func angleHandle() throws {
        var surface = Surface.empty
        surface.inputs = [input("angle", 50, 0, 360, step: 1)]
        surface.outputs = [Output(name: "cosine", label: "Cosine", formula: "cos(angle * pi / 180)", format: .number),
                           Output(name: "sine", label: "Sine", formula: "sin(angle * pi / 180)", format: .number)]
        surface.figures = [Figure(name: "circle", points: [
            FigurePoint(name: "O", x: "0", y: "0", label: "O"),
            FigurePoint(name: "A", x: "1", y: "0", label: ""),
            FigurePoint(name: "F", x: "cosine", y: "0", label: ""),
            FigurePoint(name: "P", x: "cosine", y: "sine", label: "P"),
        ], shapes: [
            FigureShape(kind: .circle, points: ["O"], radius: "1"),
            FigureShape(kind: .segment, points: ["O", "P"], tone: .main),
            FigureShape(kind: .angle, points: ["A", "O", "P"], label: "{angle}°"),
        ])]
        let figure = try #require(surface.figures?.first)
        let handles = figure.handles(in: surface)
        #expect(handles.map(\.point) == ["P"], "the point on the circle is the angle's handle")
        let handle = try #require(handles.first)
        let values = figure.dragged(handle, to: Vec2(x: -0.5, y: -0.5), in: surface, given: [:])
        #expect(near(values["angle"] ?? 0, 225), "dragging it down and left sets 225°")
        let arms = figure.drawing(in: surface, given: [:]).marks.filter { $0.id >= figure.shapes.count }
        #expect(arms.count == 1, "only the arm to A is added, since O to P is drawn")
    }

    @Test("The checker repairs near misses and drops what can't be drawn")
    func checkerRepairs() {
        var surface = pythagoras
        surface.figures = [Figure(name: "Right triangle", points: [
            FigurePoint(name: "C", x: "0", y: "0", label: "C"),
            FigurePoint(name: "B", x: "A", y: "", label: "B"),
            FigurePoint(name: "A", x: "", y: "B", label: "A"),
            FigurePoint(name: "M", x: "(Ax + B_x) / 2", y: "(A.Y + B.y) / 2", label: ""),
            FigurePoint(name: "X", x: "nonsense + 1", y: "0", label: ""),
        ], shapes: [
            FigureShape(kind: .polygon, points: ["ABC"], tone: .main),
            FigureShape(kind: .circle, points: ["M"], radius: "c / 2", tone: .guide),
            FigureShape(kind: .segment, points: ["A", "Z"]),
            FigureShape(kind: .arc, points: ["C"], radius: "1", tone: .plain),
        ])]
        _ = Checker.checkFigures(&surface)
        let figure = surface.figures?.first
        #expect(figure?.name == "rightTriangle", "figure names become identifiers")
        #expect(figure?.point("B")?.x == "a" && figure?.point("A")?.y == "b", "near-miss names are repaired")
        #expect(figure?.point("M")?.x == "(A.x + B.x) / 2" && figure?.point("M")?.y == "(A.y + B.y) / 2", "Ax, B_x and A.Y read as coordinates")
        #expect(figure?.point("X") == nil, "a point whose formula uses an unknown name is dropped")
        #expect(figure?.shapes.count == 2 && figure?.shapes.first?.points == ["A", "B", "C"], "ABC is read as three points, and broken shapes are dropped")
    }
}

@Suite("Diagrams")
struct DiagramsTests {
    @Test("Cycles, flows, hubs and trees lay out", arguments: [320.0, 353.0])
    func layouts(width: Double) {
        let water = DiagramLayout.make(diagram(.cycle, ["Evaporation", "Condensation", "Precipitation", "Collection"]), width: width)
        #expect(!water.hasOverlaps && water.routes.count == 4, "a four-stage cycle fits")
        #expect(water.frames.values.allSatisfy { $0.minX >= 0 && $0.maxX <= width }, "the cycle stays inside the width")
        let big = DiagramLayout.make(diagram(.cycle, (1...8).map { "Stage \($0)" }), width: width)
        #expect(!big.hasOverlaps, "an eight-stage cycle doesn't overlap")

        let bill = DiagramLayout.make(diagram(.flow, ["Drafted", "Introduced", "Committee", "Lok Sabha", "Rajya Sabha", "Joint sitting", "President", "Act"],
                                              edges: [(0, 1), (1, 2), (2, 3), (3, 4), (4, 6), (4, 5), (5, 6), (6, 7), (6, 3)]), width: width)
        #expect(!bill.hasOverlaps && bill.routes.count == 9, "a branching flow with a return lays out")
        #expect(Set(bill.frames.values.map(\.minY)).count == 8, "the flow has a row per stage")
        let bypass = bill.routes.first { $0.from == "n4" && $0.to == "n6" }
        #expect(bypass.map { $0.points.contains { $0.x < 20 } } == true, "the way round the joint sitting runs down the side")
        let back = bill.routes.first { $0.from == "n6" && $0.to == "n3" }
        #expect(back.map { $0.points.contains { $0.x > width - 20 } } == true, "the return to the Lok Sabha runs up the other side")

        let hub = DiagramLayout.make(diagram(.hub, ["Photosynthesis", "Light", "Water", "Carbon dioxide", "Glucose", "Oxygen"], edges: [(1, 0), (2, 0), (3, 0), (0, 4), (0, 5)]), width: width)
        #expect(!hub.hasOverlaps && hub.frames["n0"].map { near($0.center.x, width / 2) } == true, "a hub sits in the middle")

        let small = DiagramLayout.make(diagram(.tree, ["Animals", "Vertebrates", "Invertebrates"], edges: [(0, 1), (0, 2)]), width: width)
        #expect(!small.isOutline && !small.hasOverlaps, "a small tree is drawn top down")
        let broad = DiagramLayout.make(diagram(.tree, ["Vertebrates", "Fish", "Amphibians", "Reptiles", "Birds", "Mammals"], edges: [(0, 1), (0, 2), (0, 3), (0, 4), (0, 5)]), width: width)
        #expect(broad.isOutline && !broad.hasOverlaps, "a broad tree becomes an outline")
    }

    /// Nothing overlaps, no label sits on a line, no word is broken, and labels along a cycle sit outside it.
    @Test("Diagrams as Grok wrote them read cleanly", arguments: writtenDiagrams.indices, [320.0, 390.0])
    func writtenByGrok(index: Int, width: Double) {
        let diagram = writtenDiagrams[index]
        let layout = DiagramLayout.make(diagram, width: width, metrics: measured)
        let metrics = measured.scaled(layout.textScale)
        #expect(!layout.hasOverlaps, "\(diagram.name): no nodes overlap")
        #expect(layout.crowdedLabels == 0, "\(diagram.name): no edge label overlaps a node or another label")
        #expect(layout.textScale >= 0.82, "\(diagram.name): text stays close to full size")
        // At 320 points the tightest cycles can't always keep every label off every line; they
        // still never cover a node or another label.
        if width >= 390 { #expect(layout.labelsOnLines == 0, "\(diagram.name): no edge label sits on a line") }
        #expect(layout.routes.compactMap(\.labelFrame).allSatisfy { $0.minX >= 0 && $0.maxX <= width }, "\(diagram.name): labels stay inside the width")
        #expect(layout.frames.values.allSatisfy { $0.minX >= 0 && $0.maxX <= width }, "\(diagram.name): nodes stay inside the width")
        let broken = diagram.nodes.filter { node in
            guard let frame = layout.frames[node.id], let lines = layout.lines[node.id] else { return true }
            return lines.joined(separator: " ") != node.label || lines.contains { metrics.measureNode($0) > frame.width - 2 * metrics.nodePadding + 0.5 }
        }
        #expect(broken.map(\.label).isEmpty, "\(diagram.name): every word fits whole in its node")
        guard diagram.shape == .cycle else { return }
        // Along the ring, every label sits by its arc, never in the middle: outside it, or just
        // inside where a stage beside the ring has taken the outside.
        let ring = DiagramLayout.mainCycle(ids: diagram.nodes.map(\.id), edges: diagram.edges)
        let middle = ring.compactMap { layout.frames[$0]?.center }.reduce(Vec2.zero, +) / Double(ring.count)
        let inward = layout.routes.filter { route in
            guard let i = ring.firstIndex(of: route.from), let j = ring.firstIndex(of: route.to), let label = route.labelFrame,
                  (j - i + ring.count) % ring.count == 1 || (i - j + ring.count) % ring.count == 1 else { return false }
            let line = route.points[route.points.count / 2]
            return (label.center - middle).length < (line - middle).length * 0.6
        }
        #expect(inward.map(\.label).isEmpty, "\(diagram.name): labels along the ring sit by their arcs, not in the middle")
    }

    @Test("The water cycle goes round its longest loop, from the first stage")
    func mainCycle() {
        let water = writtenDiagrams[0]
        #expect(DiagramLayout.mainCycle(ids: water.nodes.map(\.id), edges: water.edges) == ["evaporation", "condensation", "precipitation", "runoff", "ocean"])
    }

    @Test("The checker makes diagram ids unique and keeps edges it can read")
    func checker() {
        var surface = Surface.empty
        surface.diagrams = [Diagram(name: "Water cycle", shape: .cycle, nodes: [
            Diagram.Node(id: "evaporation", label: "Evaporation", detail: "Sun warms water."),
            Diagram.Node(id: "evaporation", label: "Again", detail: ""),
            Diagram.Node(id: "", label: "Condensation", detail: ""),
        ], edges: [
            Diagram.Edge(from: "Evaporation", to: "condensation", label: ""),
            Diagram.Edge(from: "condensaton", to: "evaporation", label: "rain"),
            Diagram.Edge(from: "evaporation", to: "ocean", label: ""),
        ])]
        _ = Checker.checkFigures(&surface)
        let checked = surface.diagrams?.first
        #expect(checked?.name == "waterCycle" && checked?.nodes.map(\.id) == ["evaporation", "Condensation"], "diagram ids are made unique and usable")
        #expect(checked?.edges.count == 2, "edges by label or near-miss id are kept, others dropped")
    }
}
