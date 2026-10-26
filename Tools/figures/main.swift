import Foundation

// Checks the geometry behind figures and diagrams on this Mac: fitting, handles, labels and
// layout. No model involved. Build and run with Tools/figures.sh.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}
func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

func input(_ name: String, _ initial: Double, _ min: Double, _ max: Double, step: Double = 0.1, role: InputRole = .adjustable) -> Input {
    Input(name: name, label: name, format: .number, initial: initial, min: min, max: max, step: step, options: [], role: role)
}

// MARK: - Pythagoras: a right triangle with squares on its sides

let pythagoras: Surface = {
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

do {
    let figure = pythagoras.figures![0]
    let drawing = figure.drawing(in: pythagoras, given: [:])
    check(drawing.marks.count == 6, "every Pythagoras shape is drawn (got \(drawing.marks.count))")
    check(drawing.points["T"] == Vec2(x: 7, y: 3), "points can use other points' coordinates (T is \(String(describing: drawing.points["T"])))")
    let handles = figure.handles(in: pythagoras)
    check(handles.map(\.point) == ["B", "A"], "the legs' corners are the handles (got \(handles.map(\.point)))")
    check(handles.first?.inputs == ["a"], "B sets a")

    // Dragging B along the bottom sets a, snapped to its step.
    if let handle = handles.first {
        let values = figure.dragged(handle, to: Vec2(x: 5.33, y: 0.4), in: pythagoras, given: [:])
        check(near(values["a"] ?? 0, 5.3), "dragging B to x 5.33 sets a to 5.3 (got \(values))")
        let clamped = figure.dragged(handle, to: Vec2(x: 30, y: 0), in: pythagoras, given: [:])
        check(near(clamped["a"] ?? 0, 8), "dragging past the range stops at its end (got \(clamped))")
    }

    // The view covers the range, so it doesn't move while dragging, up to twice the starting size.
    let extent = figure.extent(in: pythagoras)!
    let start = drawing.bounds!
    let atMost = figure.drawing(in: pythagoras, given: ["a": 8, "b": 8]).bounds!
    check(figure.rangeExtent(in: pythagoras).map { $0.union(atMost) == $0 } == true, "the range's extent includes the largest triangle")
    check(extent.union(start) == extent && near(extent.width, start.width * 2) && near(extent.height, start.height * 2),
          "the view at rest holds the starting figure, at twice its size (\(extent) for \(start))")
    let viewport = FigureViewport(fitting: extent, width: 320, height: 320 * FigureViewport.aspect(of: extent))
    let corner = viewport.screen(Vec2(x: 3, y: 4))
    check(near(viewport.model(corner).x, 3) && near(viewport.model(corner).y, 4), "screen and figure units convert both ways")
    check(viewport.screen(Vec2(x: 0, y: 1)).y < viewport.screen(Vec2(x: 0, y: 0)).y, "y points up")

    // Labels don't land on each other.
    let sizes = Dictionary(uniqueKeysWithValues: drawing.labels.map { ($0.id, Vec2(x: 34, y: 16)) })
    let placed = drawing.placeLabels(in: viewport, sizes: sizes, bounds: Rect2(minX: 0, minY: 0, maxX: 320, maxY: 320 * FigureViewport.aspect(of: extent)))
    check(placed.count == drawing.labels.count, "every label is placed")
    let boxes = Array(placed.values)
    let overlapping = boxes.indices.flatMap { i in boxes.indices.filter { j in i < j && boxes[i].overlap(boxes[j]) > 1 } }
    check(overlapping.isEmpty, "labels don't overlap")

    // The checker keeps a good figure as it is.
    var checkedSurface = pythagoras
    let issues = Checker.checkFigures(&checkedSurface)
    check(issues.isEmpty && checkedSurface.figures == pythagoras.figures, "a good figure passes unchanged (\(issues))")
}

// Squares built on the sides go outward, whichever way round the model names the side.
do {
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
    let marks = surface.figures![0].drawing(in: surface, given: [:]).marks
    func corners(_ index: Int) -> [Vec2] {
        if case .line(let points, _) = marks.first(where: { $0.id == index })?.geometry { return points }
        return []
    }
    check(Set(corners(1)) == [Vec2(x: 0, y: 4), Vec2(x: 3, y: 0), Vec2(x: 7, y: 3), Vec2(x: 4, y: 7)], "the square on the hypotenuse is outside the triangle (\(corners(1)))")
    check(Set(corners(2)) == [Vec2(x: 0, y: 0), Vec2(x: 3, y: 0), Vec2(x: 3, y: -3), Vec2(x: 0, y: -3)], "the square on a is below it (\(corners(2)))")
    check(Set(corners(3)) == [Vec2(x: 0, y: 4), Vec2(x: 0, y: 0), Vec2(x: -4, y: 0), Vec2(x: -4, y: 4)], "the square on b is built away from B (\(corners(3)))")
}

// MARK: - A thrown ball: a path, and a launch arrow whose tip sets speed and angle

let throwSurface: Surface = {
    var surface = Surface.empty
    surface.title = "Throw"
    surface.inputs = [input("speed", 20, 5, 30, step: 1), input("angle", 45, 5, 85, step: 1), input("g", 9.81, 9.81, 9.81, role: .given)]
    surface.outputs = [
        Output(name: "flightTime", label: "Time in the air", formula: "2 * speed * sin(angle * pi / 180) / g", format: .number),
        Output(name: "range", label: "Distance", formula: "speed^2 * sin(2 * angle * pi / 180) / g", format: .number),
    ]
    surface.figures = [Figure(name: "flight", points: [
        FigurePoint(name: "O", x: "0", y: "0", label: ""),
        FigurePoint(name: "tip", x: "speed * cos(angle * pi / 180) * 0.5", y: "speed * sin(angle * pi / 180) * 0.5", label: ""),
        FigurePoint(name: "land", x: "range", y: "0", label: "{range} m"),
        FigurePoint(name: "end", x: "100", y: "0", label: ""),
    ], shapes: [
        FigureShape(kind: .segment, points: ["O", "end"], tone: .guide),
        FigureShape(kind: .path, over: "t", x: "speed * cos(angle * pi / 180) * t", y: "speed * sin(angle * pi / 180) * t - g * t^2 / 2", tone: .main).with(from: "0", to: "flightTime"),
        FigureShape(kind: .arrow, points: ["O", "tip"], label: "v", tone: .contrast),
    ])]
    return surface
}()

extension FigureShape {
    func with(from: String, to: String) -> FigureShape {
        var shape = self
        (shape.from, shape.to) = (from, to)
        return shape
    }
}

do {
    let figure = throwSurface.figures![0]
    let drawing = figure.drawing(in: throwSurface, given: [:])
    if case .line(let path, _)? = drawing.marks.first(where: { $0.shape.kind == .path })?.geometry {
        check(near(path.last!.x, 20 * 20 / 9.81, 1e-6) && near(path.last!.y, 0, 1e-6), "the path lands at the range (ends at \(path.last!))")
    } else {
        check(false, "the path is drawn")
    }
    let handles = figure.handles(in: throwSurface)
    check(handles.map(\.point) == ["tip"] && handles.first?.inputs == ["angle", "speed"], "the arrow's tip sets speed and angle (got \(handles))")
    if let handle = handles.first {
        // Straight up and 12 long, at the 0.5 scale: speed 24, angle as steep as it goes.
        let started = Date()
        let values = figure.dragged(handle, to: Vec2(x: 6, y: 6 * sqrt(3)), in: throwSurface, given: [:])
        let elapsed = Date().timeIntervalSince(started)
        check(near(values["speed"] ?? 0, 24) && near(values["angle"] ?? 0, 60), "dragging the tip sets speed 24 at 60° (got \(values))")
        check(elapsed < 0.02, "a drag step is quick (took \(Int(elapsed * 1000)) ms)")
    }
    var checkedSurface = throwSurface
    _ = Checker.checkFigures(&checkedSurface)
    check(checkedSurface.figureAxes == ["t"], "the path's t is its own")
}

// A point turned all the way round is still a handle, and an angle gets the arms no shape draws.
do {
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
    let figure = surface.figures![0]
    let handles = figure.handles(in: surface)
    check(handles.map(\.point) == ["P"], "the point on the circle is the angle's handle (got \(handles.map(\.point)))")
    if let handle = handles.first {
        let values = figure.dragged(handle, to: Vec2(x: -0.5, y: -0.5), in: surface, given: [:])
        check(near(values["angle"] ?? 0, 225), "dragging it down and left sets 225° (got \(values))")
    }
    let arms = figure.drawing(in: surface, given: [:]).marks.filter { $0.id >= figure.shapes.count }
    check(arms.count == 1, "only the arm to A is added, since O to P is drawn (got \(arms.count))")
}

// MARK: - The checker repairs near misses and drops what can't be drawn

do {
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
    let issues = Checker.checkFigures(&surface)
    let figure = surface.figures?.first
    check(figure?.name == "rightTriangle", "figure names become identifiers")
    check(figure?.point("B")?.x == "a" && figure?.point("A")?.y == "b", "near-miss names are repaired (B.x \(figure?.point("B")?.x ?? "?"), A.y \(figure?.point("A")?.y ?? "?"))")
    check(figure?.point("M")?.x == "(A.x + B.x) / 2" && figure?.point("M")?.y == "(A.y + B.y) / 2", "Ax, B_x and A.Y read as coordinates (got \(figure?.point("M")?.x ?? "?"))")
    check(figure?.point("X") == nil, "a point whose formula uses an unknown name is dropped")
    check(figure?.shapes.count == 2 && figure?.shapes.first?.points == ["A", "B", "C"], "ABC is read as three points, and broken shapes are dropped (\(issues.map(\.message)))")
}

// MARK: - Diagrams

func diagram(_ shape: Diagram.Shape, _ labels: [String], edges: [(Int, Int)] = []) -> Diagram {
    let nodes = labels.enumerated().map { Diagram.Node(id: "n\($0.offset)", label: $0.element, detail: "") }
    return Diagram(name: "d", shape: shape, nodes: nodes, edges: edges.map { Diagram.Edge(from: "n\($0.0)", to: "n\($0.1)", label: "") })
}

for width in [320.0, 353.0] {
    let water = DiagramLayout.make(diagram(.cycle, ["Evaporation", "Condensation", "Precipitation", "Collection"]), width: width)
    check(!water.hasOverlaps && water.routes.count == 4, "a four-stage cycle fits at \(Int(width)) points")
    check(water.frames.values.allSatisfy { $0.minX >= 0 && $0.maxX <= width }, "the cycle stays inside the width")
    let big = DiagramLayout.make(diagram(.cycle, (1...8).map { "Stage \($0)" }), width: width)
    check(!big.hasOverlaps, "an eight-stage cycle doesn't overlap at \(Int(width)) points")

    let bill = DiagramLayout.make(diagram(.flow, ["Drafted", "Introduced", "Committee", "Lok Sabha", "Rajya Sabha", "Joint sitting", "President", "Act"],
                                          edges: [(0, 1), (1, 2), (2, 3), (3, 4), (4, 6), (4, 5), (5, 6), (6, 7), (6, 3)]), width: width)
    check(!bill.hasOverlaps && bill.routes.count == 9, "a branching flow with a return lays out at \(Int(width)) points")
    let rows = Set(bill.frames.values.map(\.minY)).count
    check(rows == 8, "the flow has a row per stage (got \(rows) rows)")
    let bypass = bill.routes.first { $0.from == "n4" && $0.to == "n6" }
    check(bypass.map { $0.points.contains { $0.x < 20 } } == true, "the way round the joint sitting runs down the side")
    let back = bill.routes.first { $0.from == "n6" && $0.to == "n3" }
    check(back.map { $0.points.contains { $0.x > width - 20 } } == true, "the return to the Lok Sabha runs up the other side")

    let hub = DiagramLayout.make(diagram(.hub, ["Photosynthesis", "Light", "Water", "Carbon dioxide", "Glucose", "Oxygen"], edges: [(1, 0), (2, 0), (3, 0), (0, 4), (0, 5)]), width: width)
    check(!hub.hasOverlaps && hub.frames["n0"].map { near($0.center.x, width / 2) } == true, "a hub sits in the middle at \(Int(width)) points")

    let small = DiagramLayout.make(diagram(.tree, ["Animals", "Vertebrates", "Invertebrates"], edges: [(0, 1), (0, 2)]), width: width)
    check(!small.isOutline && !small.hasOverlaps, "a small tree is drawn top down")
    let broad = DiagramLayout.make(diagram(.tree, ["Vertebrates", "Fish", "Amphibians", "Reptiles", "Birds", "Mammals"], edges: [(0, 1), (0, 2), (0, 3), (0, 4), (0, 5)]), width: width)
    check(broad.isOutline && !broad.hasOverlaps, "a broad tree becomes an outline")
}

do {
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
    check(checked?.name == "waterCycle" && checked?.nodes.map(\.id) == ["evaporation", "Condensation"], "diagram ids are made unique and usable (got \(checked?.nodes.map(\.id) ?? []))")
    check(checked?.edges.count == 2, "edges by label or near-miss id are kept, others dropped (got \(checked?.edges ?? []))")
}

print(failures == 0 ? "All figure checks passed." : "\(failures) figure checks failed.")
exit(failures == 0 ? 0 : 1)
