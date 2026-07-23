import CoreGraphics

/// Czysta geometria uchwytów transformacji zaznaczonej adnotacji — bez widoków, więc testowalna
/// jednostkowo. Pracuje w układzie strony PDF (y w górę). Uchwyt „obrotu" i uchwyty skalowania
/// (rogi/krawędzie) opisujemy przez znormalizowaną pozycję w prostokącie: nx,ny ∈ {-1,0,1}.
public enum AnnotationTransform {

    /// Uchwyt na ramce zaznaczenia. nx: lewo(-1)…prawo(+1), ny: dół(-1)…góra(+1). `rotation` to kółko
    /// nad środkiem górnej krawędzi.
    public enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, rotation

        /// Składowa pozioma pozycji uchwytu (-1 lewo, 0 środek, 1 prawo).
        public var nx: CGFloat {
            switch self {
            case .topLeft, .left, .bottomLeft: return -1
            case .top, .bottom, .rotation: return 0
            case .topRight, .right, .bottomRight: return 1
            }
        }
        /// Składowa pionowa pozycji uchwytu (-1 dół, 0 środek, 1 góra).
        public var ny: CGFloat {
            switch self {
            case .bottomLeft, .bottom, .bottomRight: return -1
            case .left, .right: return 0
            case .topLeft, .top, .topRight, .rotation: return 1
            }
        }
        /// Czy to narożnik (skalowanie po dwóch osiach naraz / proporcjonalne).
        public var isCorner: Bool { nx != 0 && ny != 0 }
    }

    // MARK: - Osie obróconego prostokąta

    /// Wektory jednostkowe lokalnych osi prostokąta obróconego o `deg` stopni.
    private static func axes(_ deg: CGFloat) -> (u: CGPoint, v: CGPoint) {
        let r = deg * .pi / 180
        let c = cos(r), s = sin(r)
        return (CGPoint(x: c, y: s), CGPoint(x: -s, y: c))
    }

    // MARK: - AABB obróconego prostokąta

    /// Osiowo wyrównany prostokąt opisany na prostokącie `displaySize` obróconym o `deg` wokół `center`.
    /// Dla obrotu 0 zwraca dokładnie prostokąt `displaySize` (bez rozrostu).
    public static func boundingBox(displaySize size: CGSize, center: CGPoint, rotationDegrees deg: CGFloat) -> CGRect {
        let r = deg * .pi / 180
        let c = abs(cos(r)), s = abs(sin(r))
        let hw = size.width / 2, hh = size.height / 2
        let halfW = hw * c + hh * s
        let halfH = hw * s + hh * c
        return CGRect(x: center.x - halfW, y: center.y - halfH, width: 2 * halfW, height: 2 * halfH)
    }

    // MARK: - Kąty

    /// Sprowadza stopnie do przedziału (-180, 180].
    public static func normalizeDegrees(_ d: CGFloat) -> CGFloat {
        var r = d.truncatingRemainder(dividingBy: 360)
        if r <= -180 { r += 360 }
        if r > 180 { r -= 360 }
        return r
    }

    /// Kąt obrotu (w stopniach) wynikający z pociągnięcia uchwytu obrotu do `handlePoint`.
    /// Uchwyt skierowany prosto w górę (+y) odpowiada 0°.
    public static func rotationDegrees(center: CGPoint, handlePoint p: CGPoint) -> CGFloat {
        let phi = atan2(p.y - center.y, p.x - center.x) * 180 / .pi
        return normalizeDegrees(phi - 90)
    }

    /// Przyciąganie kąta do wielokrotności `step` (domyślnie 15°).
    public static func snapAngle(_ deg: CGFloat, step: CGFloat = 15) -> CGFloat {
        guard step > 0 else { return deg }
        return normalizeDegrees((deg / step).rounded() * step)
    }

    // MARK: - Pozycje uchwytów

    /// Pozycja uchwytu w układzie strony. Uchwyt obrotu leży `rotationArm` nad środkiem górnej krawędzi.
    public static func handlePoint(_ handle: Handle, center: CGPoint, size: CGSize,
                                   rotationDegrees deg: CGFloat, rotationArm: CGFloat = 26) -> CGPoint {
        let (u, v) = axes(deg)
        let hw = size.width / 2, hh = size.height / 2
        if handle == .rotation {
            let ext = hh + rotationArm
            return CGPoint(x: center.x + v.x * ext, y: center.y + v.y * ext)
        }
        return CGPoint(x: center.x + u.x * (handle.nx * hw) + v.x * (handle.ny * hh),
                       y: center.y + u.y * (handle.nx * hw) + v.y * (handle.ny * hh))
    }

    /// Uchwyt trafiony punktem `p` (najbliższy w promieniu `radius`), albo nil.
    public static func hitHandle(_ handles: [Handle], point p: CGPoint, center: CGPoint, size: CGSize,
                                 rotationDegrees deg: CGFloat, radius: CGFloat, rotationArm: CGFloat = 26) -> Handle? {
        var best: Handle?
        var bestDist = radius
        for h in handles {
            let hp = handlePoint(h, center: center, size: size, rotationDegrees: deg, rotationArm: rotationArm)
            let d = hypot(hp.x - p.x, hp.y - p.y)
            if d <= bestDist { bestDist = d; best = h }
        }
        return best
    }

    // MARK: - Skalowanie

    /// Nowa geometria (środek + rozmiar) po przeciągnięciu uchwytu skalowania do `cursor`.
    /// Przeciwległy narożnik/krawędź (kotwica) pozostaje nieruchomy. Dla narożnika z `proportional`
    /// zachowuje proporcje (skala po przekątnej). Rozmiar klamrowany od dołu do `minSize`.
    public static func resize(center: CGPoint, size: CGSize, rotationDegrees deg: CGFloat,
                              handle: Handle, toCursor cursor: CGPoint,
                              proportional: Bool, minSize: CGFloat = 24) -> (center: CGPoint, size: CGSize) {
        let (u, v) = axes(deg)
        let hw = size.width / 2, hh = size.height / 2
        let nx = handle.nx, ny = handle.ny

        // Kotwica: przeciwległy narożnik/krawędź (w układzie strony).
        let anchor = CGPoint(x: center.x + u.x * (-nx * hw) + v.x * (-ny * hh),
                             y: center.y + u.y * (-nx * hw) + v.y * (-ny * hh))
        let d = CGPoint(x: cursor.x - anchor.x, y: cursor.y - anchor.y)
        let projU = d.x * u.x + d.y * u.y
        let projV = d.x * v.x + d.y * v.y

        var newW = size.width
        var newH = size.height

        if proportional && handle.isCorner {
            // Rzut kursora na przekątną (kotwica → uchwyt) → jednolita skala obu wymiarów.
            let dirX = u.x * (nx * size.width) + v.x * (ny * size.height)
            let dirY = u.y * (nx * size.width) + v.y * (ny * size.height)
            let dl = hypot(dirX, dirY)
            let diag = max(hypot(size.width, size.height), 0.0001)
            let t = dl > 0 ? (d.x * dirX + d.y * dirY) / dl : 0
            let scale = max(t / diag, minSize / size.width, minSize / size.height)
            newW = size.width * scale
            newH = size.height * scale
        } else {
            if nx != 0 { newW = max(minSize, projU * nx) }
            if ny != 0 { newH = max(minSize, projV * ny) }
        }

        let nhw = newW / 2, nhh = newH / 2
        let newCenter = CGPoint(x: anchor.x + u.x * (nx * nhw) + v.x * (ny * nhh),
                                y: anchor.y + u.y * (nx * nhw) + v.y * (ny * nhh))
        return (newCenter, CGSize(width: newW, height: newH))
    }
}
