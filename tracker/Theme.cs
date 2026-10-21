using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace CharterDeskTracker;

/// <summary>Charter Desk FS colours and fonts: navy and brass, matching the website's dark theme.</summary>
public static class Theme
{
    public static readonly Color Bg = Color.FromArgb(0x0B, 0x15, 0x24);
    public static readonly Color Header = Color.FromArgb(0x07, 0x0F, 0x1B);
    public static readonly Color Card = Color.FromArgb(0x13, 0x22, 0x3A);
    public static readonly Color Card2 = Color.FromArgb(0x1A, 0x2D, 0x4A);
    public static readonly Color Line = Color.FromArgb(0x26, 0x3A, 0x5B);
    public static readonly Color Text = Color.FromArgb(0xE9, 0xEE, 0xF5);
    public static readonly Color Muted = Color.FromArgb(0x93, 0xA3, 0xBA);
    public static readonly Color Gold = Color.FromArgb(0xC9, 0xA2, 0x4E);
    public static readonly Color GoldHover = Color.FromArgb(0xD8, 0xB4, 0x63);
    public static readonly Color Navy = Color.FromArgb(0x0E, 0x1A, 0x2B);
    public static readonly Color Good = Color.FromArgb(0x3D, 0xBE, 0x7A);
    public static readonly Color Warn = Color.FromArgb(0xE3, 0xA3, 0x3B);
    public static readonly Color Bad = Color.FromArgb(0xE2, 0x57, 0x4C);

    static readonly HashSet<string> Installed = new(FontFamily.Families.Select(f => f.Name), StringComparer.OrdinalIgnoreCase);
    static string Pick(params string[] names) => names.FirstOrDefault(Installed.Contains) ?? "Segoe UI";

    public static readonly string SansName = Pick("Segoe UI Variable Text", "Segoe UI");
    public static readonly string MonoName = Pick("Cascadia Mono", "Consolas", "Courier New");

    public static Font Sans(float size, FontStyle style = FontStyle.Regular) => new(SansName, size, style);
    public static Font Semi(float size) => new(Pick("Segoe UI Semibold", "Segoe UI"), size, Pick("Segoe UI Semibold", "Segoe UI") == "Segoe UI" ? FontStyle.Bold : FontStyle.Regular);
    public static Font Mono(float size, FontStyle style = FontStyle.Regular) => new(MonoName, size, style);

    public static Color ScoreColor(int? score) => score == null ? Muted : score >= 85 ? Good : score >= 60 ? Warn : Bad;

    public static GraphicsPath Round(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        float d = radius * 2;
        if (radius <= 0) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);

    /// <summary>Dark scroll bars (Windows 10 1809+ and 11).</summary>
    public static void DarkScrollbars(IntPtr handle)
    {
        try { SetWindowTheme(handle, "DarkMode_Explorer", null); } catch { }
    }

    /// <summary>Dark title bar on Windows 10 (1809+) and 11.</summary>
    public static void DarkTitleBar(IntPtr handle)
    {
        try
        {
            int on = 1;
            if (DwmSetWindowAttribute(handle, 20, ref on, sizeof(int)) != 0) DwmSetWindowAttribute(handle, 19, ref on, sizeof(int));
        }
        catch { /* older Windows: keep the default title bar */ }
    }
}

/// <summary>A rounded panel with a hairline border.</summary>
public class Card : Panel
{
    public Color Fill { get; set; } = Theme.Card;
    public Color Border { get; set; } = Theme.Line;
    public int Radius { get; set; } = 10;

    public Card()
    {
        DoubleBuffered = true;
        SetStyle(ControlStyles.ResizeRedraw | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        BackColor = Theme.Card;
        Padding = new Padding(16, 14, 16, 14);
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Parent?.BackColor ?? Theme.Bg);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Theme.Round(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Radius);
        using var b = new SolidBrush(Fill);
        using var pen = new Pen(Border);
        g.FillPath(b, path);
        g.DrawPath(pen, path);
    }
}

/// <summary>A small caps heading inside a card.</summary>
public sealed class Caption : Label
{
    public Caption(string text)
    {
        Text = text.ToUpperInvariant();
        AutoSize = true;
        ForeColor = Theme.Muted;
        Font = Theme.Semi(8.25f);
        Margin = new Padding(0, 0, 0, 6);
    }
}

/// <summary>Flat button in the site's style: brass for the main action, outlined for the rest.</summary>
public sealed class FlatBtn : Button
{
    readonly bool _primary;
    bool _hover;

    public FlatBtn(string text, bool primary = false)
    {
        _primary = primary;
        Text = text;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Font = Theme.Semi(9.5f);
        Height = 36;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowOnly;
        MinimumSize = new Size(0, 36);
        Padding = new Padding(12, 0, 12, 0);
        Margin = new Padding(0, 0, 8, 8);
        Cursor = Cursors.Hand;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        MouseEnter += (_, _) => { _hover = true; Invalidate(); };
        MouseLeave += (_, _) => { _hover = false; Invalidate(); };
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Parent?.BackColor ?? Theme.Card);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using var path = Theme.Round(r, 7);
        Color fill, fg, border;
        if (!Enabled) { fill = Theme.Card; fg = Color.FromArgb(0x5D, 0x6D, 0x86); border = Theme.Line; }
        else if (_primary) { fill = _hover ? Theme.GoldHover : Theme.Gold; fg = Theme.Navy; border = fill; }
        else { fill = _hover ? Theme.Line : Theme.Card2; fg = Theme.Text; border = Theme.Line; }
        using (var b = new SolidBrush(fill)) g.FillPath(b, path);
        using (var p = new Pen(border)) g.DrawPath(p, path);
        TextRenderer.DrawText(g, Text, Font, Rectangle.Round(r), fg, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
    }
}

/// <summary>Status pill: a coloured dot and a short label.</summary>
public sealed class Pill : Control
{
    Color _dot = Theme.Muted;
    public Pill()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        Font = Theme.Semi(8.75f);
        Height = 28;
    }

    public void Set(string text, Color dot)
    {
        Text = text; _dot = dot;
        Width = TextRenderer.MeasureText(text, Font).Width + 40;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Parent?.BackColor ?? Theme.Header);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Theme.Round(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), (Height - 1) / 2f);
        using (var b = new SolidBrush(Theme.Card)) g.FillPath(b, path);
        using (var p = new Pen(Theme.Line)) g.DrawPath(p, path);
        using (var d = new SolidBrush(_dot)) g.FillEllipse(d, 12, Height / 2f - 4, 8, 8);
        TextRenderer.DrawText(g, Text, Font, new Rectangle(26, 0, Width - 30, Height), Theme.Text, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
    }
}

/// <summary>An instrument tile: label, big value, unit.</summary>
public sealed class Tile : Card
{
    readonly Label _label = new() { AutoSize = true, ForeColor = Theme.Muted, Font = Theme.Semi(7.75f), BackColor = Theme.Card2 };
    readonly Label _value = new() { AutoSize = true, ForeColor = Theme.Text, Font = Theme.Mono(17f), BackColor = Theme.Card2, Text = "—" };
    readonly Label _unit = new() { AutoSize = true, ForeColor = Theme.Muted, Font = Theme.Sans(8f), BackColor = Theme.Card2 };

    public Tile(string label, string unit)
    {
        Fill = Theme.Card2; BackColor = Theme.Card2; Radius = 8;
        Padding = new Padding(12, 8, 10, 8);
        Margin = new Padding(0, 0, 8, 8);
        _label.Text = label.ToUpperInvariant();
        _unit.Text = unit;
        _label.Location = new Point(12, 9);
        _value.Location = new Point(10, 26);
        _unit.Location = new Point(13, 60);
        Controls.AddRange(new Control[] { _label, _value, _unit });
        Size = new Size(124, 82);
    }

    public void Set(string value, Color? color = null, string unit = null)
    {
        if (_value.Text != value) _value.Text = value;
        _value.ForeColor = color ?? Theme.Text;
        if (unit != null && _unit.Text != unit) _unit.Text = unit;
    }
}

/// <summary>The flight's progress through its phases, drawn as a strip of steps.</summary>
public sealed class PhaseBar : Control
{
    static readonly string[] Steps = { "Boarding", "Taxi", "Takeoff", "Climb", "Cruise", "Descent", "Landing", "Taxi in", "On blocks" };
    int _index = -1;

    public PhaseBar()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Height = 46;
        Font = Theme.Sans(7.75f);
    }

    public void Set(Phase? p)
    {
        int i = p switch
        {
            null => -1,
            Phase.Waiting => 0, Phase.TaxiOut => 1, Phase.TakeoffRoll => 2, Phase.Climb => 3, Phase.Cruise => 4,
            Phase.Descent => 5, Phase.Landed => 6, Phase.TaxiIn => 7, Phase.Arrived => 8, _ => -1
        };
        if (i != _index) { _index = i; Invalidate(); }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Parent?.BackColor ?? Theme.Card);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int n = Steps.Length;
        float pad = 10, w = Width - pad * 2, y = 12;
        using (var line = new Pen(Theme.Line, 3)) g.DrawLine(line, pad, y, pad + w, y);
        if (_index > 0) using (var done = new Pen(Theme.Gold, 3)) g.DrawLine(done, pad, y, pad + w * _index / (n - 1), y);
        for (int i = 0; i < n; i++)
        {
            float x = pad + w * i / (n - 1);
            var dot = i < _index ? Theme.Gold : i == _index ? Theme.Gold : Theme.Line;
            float r = i == _index ? 7 : 5;
            using (var b = new SolidBrush(i == _index ? Theme.Card : dot)) g.FillEllipse(b, x - r, y - r, r * 2, r * 2);
            if (i == _index) using (var p = new Pen(Theme.Gold, 3)) g.DrawEllipse(p, x - r, y - r, r * 2, r * 2);
            var sz = TextRenderer.MeasureText(Steps[i], Font);
            float tx = Math.Clamp(x - sz.Width / 2f, 0, Width - sz.Width);
            TextRenderer.DrawText(g, Steps[i], Font, new Point((int)tx, 24), i == _index ? Theme.Text : Theme.Muted);
        }
    }
}

/// <summary>A score shown as a ring out of 100.</summary>
public sealed class ScoreRing : Control
{
    int? _score;
    string _label;

    public ScoreRing(string label)
    {
        _label = label;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Size = new Size(112, 132);
        Margin = new Padding(0, 0, 12, 0);
    }

    public void Set(int? score, string label = null)
    {
        _score = score;
        if (label != null) _label = label;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Parent?.BackColor ?? Theme.Card);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var r = new RectangleF(10, 6, 92, 92);
        using (var track = new Pen(Theme.Line, 8)) g.DrawEllipse(track, r);
        if (_score is int s && s > 0)
            using (var arc = new Pen(Theme.ScoreColor(s), 8) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                g.DrawArc(arc, r, -90, 360f * s / 100f);
        using var big = Theme.Mono(20f, FontStyle.Bold);
        TextRenderer.DrawText(g, _score?.ToString() ?? "—", big, Rectangle.Round(r), Theme.Text, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        using var small = Theme.Semi(8f);
        TextRenderer.DrawText(g, _label.ToUpperInvariant(), small, new Rectangle(0, 106, Width, 20), Theme.Muted, TextFormatFlags.HorizontalCenter);
    }
}
