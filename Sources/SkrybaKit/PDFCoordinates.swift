import CoreGraphics

/// Czysta geometria edytora PDF — bez zależności od widoków, więc testowalna jednostkowo.
public enum PDFCoordinateMath {
    /// Prostokąt rozpięty na dwóch przeciwległych rogach, znormalizowany do nieujemnych width/height.
    public static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Środek odcinka między dwoma punktami.
    public static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

/// Trzy konwersje, które PDFView wykonuje na żywym układzie stron. Wydzielone jako protokół,
/// by logikę „overlay → strona" dało się testować bez okna (atrapą), a w aplikacji podstawić PDFView.
public protocol PDFCoordinateSpace {
    /// Punkt z układu nakładki narzędzi do układu PDFView.
    func overlayToView(_ point: CGPoint) -> CGPoint
    /// Indeks strony najbliższej punktowi w układzie PDFView (odpowiednik nearest:true); nil, gdy brak stron.
    func pageIndex(forViewPoint point: CGPoint) -> Int?
    /// Punkt z układu PDFView do układu strony o danym indeksie.
    func viewToPage(_ point: CGPoint, pageIndex: Int) -> CGPoint
}

/// Mapowanie gestów nakładki na (strona, geometria) w układzie strony. Korzysta wyłącznie
/// z `PDFCoordinateSpace`, więc jest deterministyczne i testowalne bez żywego PDFView.
public enum PDFCoordinateMapper {
    /// Klik: punkt nakładki → (indeks strony, punkt w układzie strony). nil dla pustego dokumentu.
    public static func map(overlayPoint p: CGPoint, in space: PDFCoordinateSpace)
        -> (pageIndex: Int, pagePoint: CGPoint)? {
        let inView = space.overlayToView(p)
        guard let index = space.pageIndex(forViewPoint: inView) else { return nil }
        return (index, space.viewToPage(inView, pageIndex: index))
    }

    /// Przeciągnięcie (dwa rogi) → (strona ze środka, znormalizowany prostokąt w układzie strony).
    /// Oba rogi rzutowane są na TĘ SAMĄ stronę (wyznaczoną przez środek), więc prostokąt nie miesza
    /// układów dwóch różnych stron, a brak strony daje nil zamiast awarii (force-unwrap).
    public static func mapDragRect(from a: CGPoint, to b: CGPoint, in space: PDFCoordinateSpace)
        -> (pageIndex: Int, rect: CGRect)? {
        let mid = space.overlayToView(PDFCoordinateMath.midpoint(a, b))
        guard let index = space.pageIndex(forViewPoint: mid) else { return nil }
        let pa = space.viewToPage(space.overlayToView(a), pageIndex: index)
        let pb = space.viewToPage(space.overlayToView(b), pageIndex: index)
        return (index, PDFCoordinateMath.normalizedRect(from: pa, to: pb))
    }

    /// Ślad odręczny → (strona pierwszego punktu, punkty w układzie tej strony). Pusty ślad → nil.
    public static func mapStroke(_ points: [CGPoint], in space: PDFCoordinateSpace)
        -> (pageIndex: Int, points: [CGPoint])? {
        guard let first = points.first else { return nil }
        guard let index = space.pageIndex(forViewPoint: space.overlayToView(first)) else { return nil }
        return (index, points.map { space.viewToPage(space.overlayToView($0), pageIndex: index) })
    }
}
