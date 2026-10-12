using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace KappaSweepLauncher;

public sealed class StorageDonut : FrameworkElement
{
    private IReadOnlyList<StorageSlice> _slices = [];
    private StorageSlice? _selected;
    private readonly List<(StorageSlice Slice, Geometry Geometry)> _regions = new();
    internal Action<StorageSlice>? SliceSelected { get; set; }

    internal void SetSlices(IReadOnlyList<StorageSlice> slices)
    {
        _slices = slices;
        _selected = null;
        _regions.Clear();
        ToolTip = null;
        InvalidateVisual();
    }

    internal void SelectSlice(StorageSlice? slice) { _selected = slice; InvalidateVisual(); }

    protected override void OnRender(DrawingContext drawing)
    {
        base.OnRender(drawing);
        _regions.Clear();
        double angle = -90;
        if (_slices.Count == 0)
            drawing.DrawGeometry(new SolidColorBrush(Color.FromRgb(221, 229, 232)), null, Sector(-90, 360));
        foreach (var slice in _slices)
        {
            var sweep = slice.Percent * 3.6;
            var geometry = Sector(angle, sweep);
            _regions.Add((slice, geometry));
            var pen = new Pen(_selected == slice ? new SolidColorBrush(Color.FromRgb(23, 43, 50)) : Brushes.White,
                _selected == slice ? 2.5 : 1.5);
            drawing.DrawGeometry((Brush)new BrushConverter().ConvertFromString(slice.Color)!, pen, geometry);
            angle += sweep;
        }
    }

    internal static Geometry Sector(double start, double sweep)
    {
        Point At(double radius, double angle) => new(120 + radius * Math.Cos(angle * Math.PI / 180),
            120 + radius * Math.Sin(angle * Math.PI / 180));
        if (sweep >= 359.999999)
            return new CombinedGeometry(GeometryCombineMode.Exclude,
                new EllipseGeometry(new Point(120, 120), 110, 110), new EllipseGeometry(new Point(120, 120), 74, 74));
        var figure = new PathFigure { StartPoint = At(110, start), IsClosed = true };
        figure.Segments.Add(new ArcSegment(At(110, start + sweep), new Size(110, 110), 0, sweep > 180, SweepDirection.Clockwise, true));
        figure.Segments.Add(new LineSegment(At(74, start + sweep), true));
        figure.Segments.Add(new ArcSegment(At(74, start), new Size(74, 74), 0, sweep > 180, SweepDirection.Counterclockwise, true));
        return new PathGeometry([figure]);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var slice = _regions.FirstOrDefault(region => region.Geometry.FillContains(e.GetPosition(this))).Slice;
        Cursor = slice is null ? Cursors.Arrow : Cursors.Hand;
        ToolTip = slice?.Description;
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        var slice = _regions.FirstOrDefault(region => region.Geometry.FillContains(e.GetPosition(this))).Slice;
        if (slice is null) return;
        SliceSelected?.Invoke(slice);
        e.Handled = true;
    }
}
