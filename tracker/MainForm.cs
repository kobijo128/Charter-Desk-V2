using System.Drawing;
using System.Drawing.Drawing2D;
using System.Text.Json.Nodes;

namespace CharterDeskTracker;

public sealed class MainForm : Form
{
    const string Version = "0.3.0";
    public static bool Demo;

    Config _cfg = Config.Load();
    Api _api;
    readonly SimReader _sim = new();
    FlightRecorder _rec;
    Sample _lastSample;
    DateTime _lastPositionSent = DateTime.MinValue;
    bool _filing, _kg;

    // header
    readonly Label _pilot = new() { AutoSize = true, ForeColor = Theme.Text, Font = Theme.Semi(9.75f), BackColor = Theme.Header, Margin = new Padding(0, 10, 14, 0) };
    readonly Pill _simPill = new() { Margin = new Padding(0, 4, 10, 0) };
    readonly FlatBtn _setup = new("Setup");

    // bookings
    readonly ListBox _bookings = new()
    {
        Dock = DockStyle.Fill, IntegralHeight = false, BorderStyle = BorderStyle.None, DrawMode = DrawMode.OwnerDrawFixed,
        ItemHeight = 70, BackColor = Theme.Card, ForeColor = Theme.Text
    };
    readonly Label _noBookings = new() { AutoSize = false, Dock = DockStyle.Fill, ForeColor = Theme.Muted, BackColor = Theme.Card, Font = Theme.Sans(9.5f), Visible = false,
        Text = "No bookings ready to fly.\n\nWin a bid or accept a phone booking on the Charter Desk website, then press Refresh." };
    readonly FlatBtn _start = new("Start flight", primary: true) { Enabled = false };
    readonly FlatBtn _refresh = new("Refresh");
    readonly FlatBtn _abort = new("Stop tracking") { Enabled = false };
    readonly FlatBtn _retry = new("Send saved reports") { Visible = false };

    // current flight
    readonly Label _route = new() { AutoSize = true, ForeColor = Theme.Text, Font = Theme.Semi(17f), BackColor = Theme.Card, Text = "No flight", Margin = new Padding(0, 0, 0, 0) };
    readonly Label _sub = new() { AutoSize = true, ForeColor = Theme.Muted, Font = Theme.Sans(9.5f), BackColor = Theme.Card, Text = "Pick a booking, load the aircraft at the gate and press Start flight.", Margin = new Padding(0, 2, 0, 10) };
    readonly Label _phase = new() { AutoSize = true, ForeColor = Theme.Gold, Font = Theme.Semi(11f), BackColor = Theme.Card, Margin = new Padding(0, 0, 0, 6) };
    readonly PhaseBar _phaseBar = new() { Dock = DockStyle.Top, BackColor = Theme.Card, Margin = new Padding(0, 0, 0, 4) };
    readonly Label _times = new() { AutoSize = true, ForeColor = Theme.Muted, Font = Theme.Mono(9f), BackColor = Theme.Card };

    // instruments
    readonly Tile _tGs = new("Ground speed", "kt"), _tIas = new("Airspeed", "kt IAS"), _tAlt = new("Altitude", "ft"), _tVs = new("Vertical speed", "fpm");
    readonly Tile _tG = new("G-force", "g"), _tAtt = new("Pitch / bank", "degrees"), _tFuel = new("Fuel on board", "lb"), _tComfort = new("Comfort", "out of 100");

    // cabin call
    readonly Card _cabin = new() { Dock = DockStyle.Top, AutoSize = true, Fill = Theme.Card2, Border = Theme.Gold, BackColor = Theme.Card2, Visible = false, Margin = new Padding(0, 0, 0, 12) };
    readonly Caption _cabinTitle = new("Cabin call") { BackColor = Theme.Card2, ForeColor = Theme.Gold };
    readonly Label _cabinMsg = new() { AutoSize = true, MaximumSize = new Size(560, 0), Font = Theme.Sans(10.5f), ForeColor = Theme.Text, BackColor = Theme.Card2, Margin = new Padding(0, 0, 0, 10) };
    readonly FlowLayoutPanel _cabinBtns = new() { AutoSize = true, BackColor = Theme.Card2, Margin = new Padding(0) };
    long _cabinId;

    // landing report
    readonly Card _score = new() { Dock = DockStyle.Top, AutoSize = true, Visible = false, Margin = new Padding(0, 0, 0, 12) };
    readonly Caption _scoreTitle = new("Landing report") { BackColor = Theme.Card };
    readonly ScoreRing _ringLanding = new("Landing") { BackColor = Theme.Card };
    readonly ScoreRing _ringComfort = new("Comfort") { BackColor = Theme.Card };
    readonly Label _points = new() { AutoSize = true, ForeColor = Theme.Gold, Font = Theme.Mono(15f, FontStyle.Bold), BackColor = Theme.Card, Text = "", Margin = new Padding(0, 4, 0, 0) };
    readonly Label _result = new() { AutoSize = true, MaximumSize = new Size(560, 0), ForeColor = Theme.Muted, Font = Theme.Sans(9f), BackColor = Theme.Card, Margin = new Padding(0, 8, 0, 0) };
    readonly Dictionary<string, Label> _stats = new();

    // log
    readonly TextBox _log = new()
    {
        Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, BorderStyle = BorderStyle.None,
        BackColor = Theme.Card, ForeColor = Theme.Muted, Font = Theme.Mono(8.75f)
    };

    readonly System.Windows.Forms.Timer _tick = new() { Interval = 250 };
    readonly System.Windows.Forms.Timer _connect = new() { Interval = 5000 };

    public MainForm()
    {
        Text = $"Charter Desk FS Tracker {Version}";
        Width = 1120; Height = 780; MinimumSize = new Size(940, 640);
        BackColor = Theme.Bg; ForeColor = Theme.Text;
        Font = Theme.Sans(9.5f);
        StartPosition = FormStartPosition.CenterScreen;
        DoubleBuffered = true;

        Controls.Add(BuildBody());
        Controls.Add(BuildHeader());

        _setup.Click += (_, _) => ShowSetup();
        _refresh.Click += async (_, _) => await LoadBookings();
        _bookings.SelectedIndexChanged += (_, _) => UpdateButtons();
        _bookings.DrawItem += DrawBooking;
        _start.Click += async (_, _) => await StartFlight();
        _abort.Click += (_, _) =>
        {
            if (MessageBox.Show(this, "Stop tracking this flight? The booking stays open and you can start it again from the gate.", "Stop tracking",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                StopTracking("Tracking stopped. The booking stays open; start it again from the gate.");
        };
        _retry.Click += async (_, _) => await SendSaved();
        _tick.Tick += async (_, _) => await OnTick();
        _connect.Tick += (_, _) => TryConnect();

        HandleCreated += (_, _) => Theme.DarkTitleBar(Handle);
        Shown += async (_, _) =>
        {
            if (Demo) return;
            if (!_cfg.IsComplete) ShowSetup();
            else { _api = new Api(_cfg); await LoadBookings(); await SendSaved(); }
            TryConnect();
            _connect.Start();
            _tick.Start();
        };
        FormClosing += (_, e) =>
        {
            if (_rec != null && _rec.Phase != Phase.Arrived && _rec.Phase != Phase.Waiting &&
                MessageBox.Show(this, "A flight is being tracked. Close the tracker and lose it?", "Flight in progress",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
                e.Cancel = true;
        };
        UpdateSavedButton();
        Log($"Charter Desk FS Tracker {Version}");
    }

    // ---------- layout ----------

    Control BuildHeader()
    {
        var header = new Panel { Dock = DockStyle.Top, Height = 64, BackColor = Theme.Header };
        header.Paint += (_, e) =>
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            // the tail-fin mark from the website
            using (var mark = new GraphicsPath())
            {
                mark.AddPolygon(new[] { new PointF(20, 46), new PointF(28, 18), new PointF(35, 18), new PointF(31, 36), new PointF(46, 36), new PointF(46, 46) });
                using var b = new SolidBrush(Theme.Gold);
                g.FillPath(b, mark);
            }
            using var title = Theme.Semi(14f);
            using var fs = Theme.Semi(14f);
            TextRenderer.DrawText(g, "Charter Desk", title, new Point(56, 12), Theme.Text);
            var w = TextRenderer.MeasureText(g, "Charter Desk", title, Size.Empty, TextFormatFlags.NoPadding).Width;
            TextRenderer.DrawText(g, "FS", fs, new Point(56 + w + 4, 12), Theme.Gold, TextFormatFlags.NoPadding);
            using var sub = Theme.Semi(7.75f);
            TextRenderer.DrawText(g, "FLIGHT TRACKER", sub, new Point(58, 38), Theme.Muted);
            using var line = new Pen(Theme.Line);
            g.DrawLine(line, 0, header.Height - 1, header.Width, header.Height - 1);
        };
        var right = new FlowLayoutPanel { Dock = DockStyle.Right, AutoSize = true, FlowDirection = FlowDirection.RightToLeft, WrapContents = false, BackColor = Theme.Header, Padding = new Padding(0, 14, 16, 0) };
        _setup.Margin = new Padding(0, 0, 0, 0);
        _setup.BackColor = Theme.Header;
        right.Controls.AddRange(new Control[] { _setup, _simPill, _pilot });
        header.Controls.Add(right);
        _simPill.Set("Waiting for the sim", Theme.Muted);
        return header;
    }

    Control BuildBody()
    {
        var body = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Padding = new Padding(16), BackColor = Theme.Bg };
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 340));
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        body.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        body.Controls.Add(BuildBookings(), 0, 0);
        body.Controls.Add(BuildFlight(), 1, 0);
        return body;
    }

    Control BuildBookings()
    {
        var card = new Card { Dock = DockStyle.Fill, Margin = new Padding(0, 0, 16, 0) };
        var t = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, BackColor = Theme.Card };
        t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        t.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        t.Controls.Add(new Caption("Bookings ready to fly") { BackColor = Theme.Card }, 0, 0);
        var listHost = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Card, Margin = new Padding(0, 0, 0, 10) };
        listHost.Controls.Add(_bookings);
        listHost.Controls.Add(_noBookings);
        t.Controls.Add(listHost, 0, 1);
        var btns = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, BackColor = Theme.Card, Margin = new Padding(0) };
        foreach (var b in new[] { _start, _refresh, _abort, _retry }) b.BackColor = Theme.Card;
        btns.Controls.AddRange(new Control[] { _start, _refresh, _abort, _retry });
        t.Controls.Add(btns, 0, 2);
        card.Controls.Add(t);
        return card;
    }

    Control BuildFlight()
    {
        var col = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, BackColor = Theme.Bg, Margin = new Padding(0), AutoScroll = true };
        for (int i = 0; i < 4; i++) col.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        col.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        // current flight
        var flight = new Card { Dock = DockStyle.Top, AutoSize = true, Margin = new Padding(0, 0, 0, 12) };
        var ft = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1, BackColor = Theme.Card };
        ft.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        ft.Controls.Add(new Caption("Current flight") { BackColor = Theme.Card });
        ft.Controls.Add(_route);
        ft.Controls.Add(_sub);
        ft.Controls.Add(_phase);
        ft.Controls.Add(_phaseBar);
        _phaseBar.Anchor = AnchorStyles.Left | AnchorStyles.Right;
        ft.Controls.Add(_times);
        flight.Controls.Add(ft);
        col.Controls.Add(flight, 0, 0);

        // instruments
        var tiles = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, BackColor = Theme.Bg, Margin = new Padding(0, 0, 0, 4) };
        tiles.Controls.AddRange(new Control[] { _tGs, _tIas, _tAlt, _tVs, _tG, _tAtt, _tFuel, _tComfort });
        col.Controls.Add(tiles, 0, 1);

        // cabin call
        var ct = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1, BackColor = Theme.Card2 };
        ct.Controls.Add(_cabinTitle);
        ct.Controls.Add(_cabinMsg);
        ct.Controls.Add(_cabinBtns);
        _cabin.Controls.Add(ct);
        col.Controls.Add(_cabin, 0, 2);

        // landing report
        var st = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1, BackColor = Theme.Card };
        st.Controls.Add(_scoreTitle);
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, BackColor = Theme.Card, Margin = new Padding(0) };
        var rings = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, BackColor = Theme.Card, Margin = new Padding(0, 0, 12, 0) };
        var ringRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false, BackColor = Theme.Card, Margin = new Padding(0) };
        ringRow.Controls.AddRange(new Control[] { _ringLanding, _ringComfort });
        rings.Controls.Add(ringRow);
        rings.Controls.Add(_points);
        row.Controls.Add(rings);
        var grid = new TableLayoutPanel { AutoSize = true, ColumnCount = 4, BackColor = Theme.Card, Margin = new Padding(0, 4, 0, 0) };
        string[] names = { "Landing rate", "G at touchdown", "Bounces", "Runway", "Touchdown", "Centreline", "Speed at touchdown", "Pitch at touchdown", "Wind", "Block time", "Air time", "Fuel used" };
        for (int i = 0; i < names.Length; i++)
        {
            var k = new Label { Text = names[i], AutoSize = true, ForeColor = Theme.Muted, Font = Theme.Sans(8.5f), BackColor = Theme.Card, Margin = new Padding(0, 3, 10, 3) };
            var v = new Label { Text = "—", AutoSize = true, ForeColor = Theme.Text, Font = Theme.Mono(9.5f), BackColor = Theme.Card, Margin = new Padding(0, 3, 22, 3) };
            _stats[names[i]] = v;
            grid.Controls.Add(k, (i % 2) * 2, i / 2);
            grid.Controls.Add(v, (i % 2) * 2 + 1, i / 2);
        }
        row.Controls.Add(grid);
        st.Controls.Add(row);
        st.Controls.Add(_result);
        _score.Controls.Add(st);
        col.Controls.Add(_score, 0, 3);

        // log
        var logCard = new Card { Dock = DockStyle.Fill, Margin = new Padding(0), MinimumSize = new Size(0, 120) };
        var lt = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, BackColor = Theme.Card };
        lt.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        lt.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        lt.Controls.Add(new Caption("Flight log") { BackColor = Theme.Card });
        lt.Controls.Add(_log);
        logCard.Controls.Add(lt);
        col.Controls.Add(logCard, 0, 4);
        return col;
    }

    void DrawBooking(object sender, DrawItemEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var bg = new SolidBrush(Theme.Card)) g.FillRectangle(bg, e.Bounds);
        if (e.Index < 0 || e.Index >= _bookings.Items.Count || _bookings.Items[e.Index] is not Booking b) return;
        bool sel = (e.State & DrawItemState.Selected) != 0;
        var r = new RectangleF(e.Bounds.X + 1, e.Bounds.Y + 3, e.Bounds.Width - 3, e.Bounds.Height - 6);
        using (var path = Theme.Round(r, 8))
        {
            using var fill = new SolidBrush(sel ? Theme.Card2 : Theme.Card);
            using var pen = new Pen(sel ? Theme.Gold : Theme.Line);
            g.FillPath(fill, path);
            g.DrawPath(pen, path);
        }
        int x = e.Bounds.X + 14, y = e.Bounds.Y + 10;
        using var mono = Theme.Mono(8.5f, FontStyle.Bold);
        using var big = Theme.Semi(12.5f);
        using var small = Theme.Sans(8.5f);
        TextRenderer.DrawText(g, b.Flt, mono, new Point(x, y), Theme.Gold);
        var tag = b.Kind == "ferry" ? "POSITIONING" : $"{b.Pax} PAX";
        var tw = TextRenderer.MeasureText(tag, mono).Width;
        TextRenderer.DrawText(g, tag, mono, new Point(e.Bounds.Right - tw - 12, y), Theme.Muted);
        TextRenderer.DrawText(g, $"{b.From}  →  {b.To}", big, new Point(x - 2, y + 15), Theme.Text);
        var dep = b.DepAt.HasValue ? $" · {(b.Kind == "ferry" ? "arrive by" : "dep")} {b.DepAt.Value:HH:mm}Z" : "";
        TextRenderer.DrawText(g, $"{b.Reg} · {b.TypeName}{dep}", small, new Rectangle(x, y + 39, e.Bounds.Width - 28, 18), Theme.Muted, TextFormatFlags.EndEllipsis);
    }

    // ---------- behaviour ----------

    void Log(string msg)
    {
        if (string.IsNullOrEmpty(msg)) return;
        _log.AppendText($"{DateTime.Now:HH:mm:ss}  {msg}{Environment.NewLine}");
    }

    void ShowSetup()
    {
        using var f = new Form
        {
            Text = "Tracker setup", Width = 540, Height = 250, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
            MaximizeBox = false, MinimizeBox = false, BackColor = Theme.Bg, ForeColor = Theme.Text, Font = Theme.Sans(9.5f)
        };
        f.HandleCreated += (_, _) => Theme.DarkTitleBar(f.Handle);
        var lbl = new Label { Text = "Paste the tracker setup code from your Profile page on the Charter Desk FS website:", Dock = DockStyle.Top, Height = 44, Padding = new Padding(14, 14, 14, 0) };
        var box = new TextBox { Dock = DockStyle.Top, Multiline = true, Height = 80, BackColor = Theme.Card, ForeColor = Theme.Text, BorderStyle = BorderStyle.FixedSingle, Font = Theme.Mono(9f) };
        var boxHost = new Panel { Dock = DockStyle.Top, Height = 96, Padding = new Padding(14, 4, 14, 8) };
        boxHost.Controls.Add(box);
        var ok = new FlatBtn("Save", primary: true) { DialogResult = DialogResult.OK, Anchor = AnchorStyles.Right | AnchorStyles.Bottom, BackColor = Theme.Bg };
        var okHost = new Panel { Dock = DockStyle.Bottom, Height = 52, Padding = new Padding(14, 6, 14, 10) };
        ok.Dock = DockStyle.Right;
        okHost.Controls.Add(ok);
        f.Controls.AddRange(new Control[] { okHost, boxHost, lbl });
        f.AcceptButton = ok;
        if (f.ShowDialog(this) != DialogResult.OK) return;
        try
        {
            _cfg = Config.FromSetupCode(box.Text);
            _cfg.Save();
            _api = new Api(_cfg);
            Log("Setup saved.");
            _ = LoadBookings();
        }
        catch
        {
            MessageBox.Show(this, "That code wasn't recognised. Copy it again from the Profile page.", "Setup", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    void TryConnect()
    {
        if (_sim.IsOpen) { _simPill.Set($"{_sim.SimName} connected", Theme.Good); return; }
        if (_sim.TryConnect(out _))
        {
            _simPill.Set($"{_sim.SimName} connected", Theme.Good);
            Log($"Connected to {_sim.SimName} through FSUIPC.");
        }
        else _simPill.Set("Waiting for the sim", Theme.Warn);
        UpdateButtons();
    }

    async Task LoadBookings()
    {
        if (_api == null) return;
        try
        {
            var s = await _api.Session();
            _pilot.Text = s.Pilot;
            _kg = s.Weight == "kg";
            _bookings.Items.Clear();
            foreach (var t in s.Trips) _bookings.Items.Add(t);
            _noBookings.Visible = s.Trips.Count == 0;
            _bookings.Visible = s.Trips.Count > 0;
            if (s.Trips.Count > 0) _bookings.SelectedIndex = 0;
        }
        catch (Exception ex) { Log("Couldn't load bookings: " + ex.Message); }
        UpdateButtons();
    }

    void UpdateButtons()
    {
        bool tracking = _rec != null && _rec.Phase != Phase.Arrived;
        _start.Enabled = !tracking && _sim.IsOpen && _bookings.SelectedItem is Booking;
        _abort.Enabled = tracking;
        _bookings.Enabled = !tracking;
        _refresh.Enabled = !tracking;
    }

    async Task StartFlight()
    {
        if (_bookings.SelectedItem is not Booking b || _lastSample == null) return;
        var s = _lastSample;
        var dist = Geo.Nm(s.Lat, s.Lon, b.FromLat, b.FromLon);
        if (dist > 3)
        {
            MessageBox.Show(this, $"Your aircraft is {dist:0} nm from {b.From}. Load the flight at {b.From} first.", "Wrong airport", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        if (!s.OnGround || s.GsKt > 2)
        {
            MessageBox.Show(this, "Start tracking while parked at the gate or stand.", "Not parked", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        if (b.SimMatch.Count > 0 && !b.SimMatch.Any(w => s.Title.Contains(w, StringComparison.OrdinalIgnoreCase)) &&
            MessageBox.Show(this, $"The loaded aircraft is \"{s.Title}\", but this booking is for a {b.TypeName}. Staff will need to review the report. Start anyway?",
                "Aircraft type", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
            return;
        try { await _api.Start(b.Id); }
        catch (Exception ex) { Log("Couldn't start: " + ex.Message); return; }

        _rec = new FlightRecorder(b) { Sim = _sim.SimName };
        _rec.Log += Log;
        _rec.Arrived += async () => await FileReport();
        Log($"Tracking {b.Flt} {b.From} → {b.To}. Release the parking brake and taxi when ready.");
        _route.Text = $"{b.Flt}   {b.From} → {b.To}";
        _sub.Text = $"{b.Reg} · {b.TypeName} · {(b.Kind == "ferry" ? "positioning, no passengers" : $"{b.Pax} passenger{(b.Pax == 1 ? "" : "s")}")}";
        _score.Visible = false;
        ResetStats();
        UpdateButtons();
    }

    void StopTracking(string message)
    {
        _rec = null;
        _route.Text = "No flight";
        _sub.Text = "Pick a booking, load the aircraft at the gate and press Start flight.";
        _phase.Text = ""; _times.Text = "";
        _phaseBar.Set(null);
        Log(message);
        UpdateButtons();
    }

    static string Hm(TimeSpan t) => $"{(int)t.TotalHours}:{t.Minutes:00}";

    async Task OnTick()
    {
        if (!_sim.IsOpen) return;
        Sample s;
        try { s = _sim.Read(); }
        catch (Exception ex)
        {
            Log("Lost the sim connection: " + ex.Message);
            _sim.Dispose();
            _simPill.Set("Sim disconnected", Theme.Bad);
            UpdateButtons();
            return;
        }
        _lastSample = s;
        UpdateTiles(s);

        if (_rec == null) return;
        _rec.Update(s);
        _phaseBar.Set(_rec.Phase);
        _phase.Text = (_rec.Phase switch
        {
            Phase.Waiting => "Boarding · release the brake and taxi when ready",
            Phase.TaxiOut => "Taxiing out",
            Phase.TakeoffRoll => "Takeoff roll",
            Phase.Climb => "Climbing",
            Phase.Cruise => "Cruise",
            Phase.Descent => "Descending",
            Phase.Landed => "Landed · rolling out",
            Phase.TaxiIn => "Taxiing in · park and set the brake",
            Phase.Arrived => "On blocks",
            var p => p.ToString()
        }) + (s.Paused ? "  ·  PAUSED" : "");
        var now = DateTime.UtcNow;
        var parts = new List<string>();
        if (_rec.BlockOff is DateTime bo) parts.Add($"BLOCK {Hm((_rec.BlockOn ?? now) - bo)}");
        if (_rec.Takeoff is DateTime to) parts.Add($"AIR {Hm((_rec.Landing ?? now) - to)}");
        if (_rec.DistanceNm > 0) parts.Add($"FLOWN {_rec.DistanceNm:0} NM");
        _times.Text = string.Join("   ·   ", parts);
        _tComfort.Set(_rec.ComfortScore.ToString(), Theme.ScoreColor(_rec.ComfortScore));

        if (_rec.LandingFpm.HasValue && !_score.Visible && _rec.Phase is Phase.Landed or Phase.TaxiIn)
        {
            ShowLocalScore();
            _score.Visible = true;
        }
        if (_rec.Phase == Phase.Arrived || _rec.Phase == Phase.TaxiIn) _cabin.Visible = false;
        if (_rec.Phase != Phase.Waiting && _rec.Phase != Phase.Arrived && (now - _lastPositionSent).TotalSeconds >= 15)
        {
            _lastPositionSent = now;
            try { ShowCabin((await _api.Ping(_rec.Booking.Id, s, _rec.Phase))?["request"]); } catch { /* live map only; ignore blips */ }
        }
    }

    void UpdateTiles(Sample s)
    {
        _tGs.Set($"{s.GsKt:0}");
        _tIas.Set($"{s.IasKt:0}");
        _tAlt.Set($"{s.AltFt:N0}");
        _tVs.Set($"{(s.OnGround ? 0 : s.VsFpm):+0;-0;0}", !s.OnGround && s.VsFpm < -3500 ? Theme.Warn : null);
        _tG.Set($"{s.G:0.00}", Math.Abs(s.G - 1) > 0.25 && !s.OnGround ? Theme.Warn : null);
        _tAtt.Set($"{s.PitchDeg:+0;-0;0}/{s.BankDeg:+0;-0;0}", Math.Abs(s.BankDeg) > 30 ? Theme.Warn : null);
        _tFuel.Set(_kg ? $"{s.FuelLb * 0.453592:N0}" : $"{s.FuelLb:N0}", null, _kg ? "kg" : "lb");
        if (_rec == null) _tComfort.Set("—");
    }

    void ResetStats()
    {
        foreach (var v in _stats.Values) v.Text = "—";
        _ringLanding.Set(null); _ringComfort.Set(null);
        _points.Text = ""; _result.Text = "";
        _scoreTitle.Text = "LANDING REPORT";
    }

    void SetStat(string k, string v, Color? c = null)
    {
        if (!_stats.TryGetValue(k, out var l)) return;
        l.Text = string.IsNullOrEmpty(v) ? "—" : v;
        l.ForeColor = c ?? Theme.Text;
    }

    static Color FpmColor(double fpm) => fpm <= 180 ? Theme.Good : fpm <= 400 ? Theme.Warn : Theme.Bad;

    void ShowLocalScore()
    {
        var r = _rec;
        _scoreTitle.Text = "LANDING REPORT · PROVISIONAL";
        _ringLanding.Set(r.LandingScoreEstimate);
        _ringComfort.Set(r.ComfortScore);
        if (r.LandingFpm is double fpm) SetStat("Landing rate", $"{fpm:0} fpm", FpmColor(fpm));
        if (r.LandingG is double g) SetStat("G at touchdown", $"{g:0.00} g", g > 1.4 ? Theme.Warn : null);
        SetStat("Bounces", r.Bounces.ToString(), r.Bounces > 0 ? Theme.Warn : null);
        if (r.TouchdownSample is Sample td)
        {
            SetStat("Speed at touchdown", $"{td.IasKt:0} kt IAS");
            SetStat("Pitch at touchdown", $"{td.PitchDeg:0.0}°", td.PitchDeg < -0.5 ? Theme.Bad : null);
            SetStat("Wind", $"{td.WindDir:000}° / {td.WindKt:0} kt");
        }
        SetStat("Runway", "after filing"); SetStat("Touchdown", "after filing"); SetStat("Centreline", "after filing");
        _result.Text = "Runway and centreline accuracy are worked out when the report is filed at block on.";
    }

    void ShowServerScore(JsonNode res)
    {
        int? ls = res?["landing_score"]?.GetValue<int>(), cs = res?["comfort_score"]?.GetValue<int>();
        _scoreTitle.Text = "LANDING REPORT";
        _ringLanding.Set(ls); _ringComfort.Set(cs);
        var pts = res?["points"]?.GetValue<int>() ?? 0;
        _points.Text = $"+{pts} pts";
        var st = res?["stats"];
        var td = st?["touchdown"];
        if (td?["runway"] != null)
        {
            SetStat("Runway", $"{td["runway"]?.GetValue<string>()} ({td["length_ft"]?.GetValue<double>() ?? 0:N0} ft)");
            var tdFt = td["td_ft"]?.GetValue<double>() ?? 0;
            SetStat("Touchdown", tdFt < 0 ? $"{-tdFt:0} ft short" : $"{tdFt:N0} ft past threshold", tdFt < 0 || tdFt > 2500 ? Theme.Warn : null);
            var cl = td["cl_m"]?.GetValue<double>() ?? 0;
            var clMax = td["cl_max_m"]?.GetValue<double>();
            SetStat("Centreline", $"{Math.Abs(cl):0.0} m {(cl > 0.05 ? "R" : cl < -0.05 ? "L" : "")}{(clMax.HasValue ? $" · max {clMax:0.0} m" : "")}", Math.Abs(cl) > 5 ? Theme.Warn : Theme.Good);
        }
        else
        {
            SetStat("Runway", "no runway data"); SetStat("Touchdown", "—"); SetStat("Centreline", "—");
        }
        if (_rec != null)
        {
            if (_rec.BlockOff is DateTime bo && _rec.BlockOn is DateTime bn) SetStat("Block time", Hm(bn - bo));
            if (_rec.Takeoff is DateTime to && _rec.Landing is DateTime ld) SetStat("Air time", Hm(ld - to));
            var used = Math.Max(0, _rec.FuelStart - _rec.FuelEnd);
            SetStat("Fuel used", _kg ? $"{used * 0.453592:N0} kg" : $"{used:N0} lb");
        }
        _score.Visible = true;
    }

    void ShowCabin(JsonNode req)
    {
        if (req == null) { _cabin.Visible = false; _cabinId = 0; return; }
        var id = req["id"]!.GetValue<long>();
        if (id == _cabinId) return;
        _cabinId = id;
        _cabinTitle.Text = $"CABIN CALL · SEAT {req["seat"]} · {req["who"]}".ToUpperInvariant();
        _cabinMsg.Text = $"\"{req["message"]}\"\nAnswer within 5 minutes.";
        _cabinBtns.Controls.Clear();
        int i = 0;
        foreach (var c in req["choices"]!.AsArray())
        {
            int choice = i++;
            var b = new FlatBtn(c!.GetValue<string>(), primary: choice == 0) { BackColor = Theme.Card2 };
            b.Click += async (_, _) =>
            {
                try
                {
                    var r = await _api.Answer(id, choice);
                    Log($"Seat {req["seat"]}: {r?["reply"]}");
                }
                catch (Exception ex) { Log(ex.Message); }
                _cabin.Visible = false;
            };
            _cabinBtns.Controls.Add(b);
        }
        _cabin.Visible = true;
        Log($"Cabin call from seat {req["seat"]}: {req["message"]}");
        System.Media.SystemSounds.Asterisk.Play();
        if (WindowState == FormWindowState.Minimized) FlashTitle();
    }

    void FlashTitle()
    {
        var t = new System.Windows.Forms.Timer { Interval = 700 };
        int n = 0; var title = Text;
        t.Tick += (_, _) => { Text = n % 2 == 0 ? "● Cabin call" : title; if (++n > 10 || WindowState != FormWindowState.Minimized) { Text = title; t.Stop(); t.Dispose(); } };
        t.Start();
    }

    async Task FileReport()
    {
        if (_filing || _rec == null) return;
        _filing = true;
        var rec = _rec;
        var report = rec.BuildReport(Version);
        Log("Filing flight report…");
        try
        {
            var res = await _api.File(rec.Booking.Id, report);
            ShowServerScore(res);
            ShowResult(res);
        }
        catch (Exception ex)
        {
            Directory.CreateDirectory(Config.PendingDir);
            File.WriteAllText(Path.Combine(Config.PendingDir, $"{rec.Booking.Id}.json"), report.ToJsonString());
            Log("Couldn't send the report (" + ex.Message + "). It's saved and will be sent when you press Send saved reports.");
            _result.Text = "The report couldn't be sent yet. It's saved on this computer: press Send saved reports when you're back online.";
            UpdateSavedButton();
        }
        finally
        {
            _filing = false;
            _rec = null;
            UpdateButtons();
            await LoadBookings();
        }
    }

    void ShowResult(JsonNode res)
    {
        var status = res?["status"]?.GetValue<string>() ?? "";
        var pts = res?["points"]?.GetValue<int>() ?? 0;
        if (status == "accepted")
        {
            var net = res["net"]?.GetValue<decimal>() ?? 0;
            var rep = res["rep_delta"]?.GetValue<decimal>() ?? 0;
            var msg = $"Report accepted. Net {(net < 0 ? "-" : "")}${Math.Abs(net):N0}, reputation {(rep >= 0 ? "+" : "")}{rep:0.0}, {pts} points. {res["note"]}";
            Log(msg);
            _result.Text = msg;
            _result.ForeColor = Theme.Text;
        }
        else
        {
            var failed = new List<string>();
            if (res?["checks"] is JsonObject c)
                foreach (var kv in c)
                    if (kv.Value?["ok"]?.GetValue<bool>() == false) failed.Add(kv.Key);
            var msg = $"Report filed and waiting for staff review{(failed.Count > 0 ? " (checks to review: " + string.Join(", ", failed) + ")" : "")}. Points are added when it's accepted.";
            Log(msg);
            _result.Text = msg;
            _result.ForeColor = Theme.Warn;
        }
        _phase.Text = "Report filed · see the full report on the website";
    }

    async Task SendSaved()
    {
        if (_api == null || !Directory.Exists(Config.PendingDir)) { UpdateSavedButton(); return; }
        foreach (var path in Directory.GetFiles(Config.PendingDir, "*.json"))
        {
            if (!long.TryParse(Path.GetFileNameWithoutExtension(path), out var tripId)) continue;
            try
            {
                var report = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
                var res = await _api.File(tripId, report);
                File.Delete(path);
                ShowResult(res);
            }
            catch (ApiException ex) when (ex.Status == 400)
            {
                Log($"Saved report for booking {tripId} was refused: {ex.Message}");
                File.Move(path, path + ".refused", true);
            }
            catch (Exception ex) { Log("Still can't send saved reports: " + ex.Message); break; }
        }
        UpdateSavedButton();
    }

    void UpdateSavedButton()
    {
        _retry.Visible = Directory.Exists(Config.PendingDir) && Directory.GetFiles(Config.PendingDir, "*.json").Length > 0;
    }

    /// <summary>Fills the window with sample data and saves a picture of it (used by the build to check the layout).</summary>
    public void SaveDemoScreenshot(string path)
    {
        _tick.Stop(); _connect.Stop();
        _pilot.Text = "ALT01 · Altus Executive Air Charter · 1,240 pts";
        _simPill.Set("MSFS connected", Theme.Good);
        var b1 = new Booking { Id = 1, Flt = "ALT104", Kind = "charter", From = "EGJJ", To = "LFPB", Reg = "ZJ-ALT", TypeName = "Embraer Phenom 300E", Pax = 5, DepAt = DateTime.UtcNow.AddMinutes(40) };
        var b2 = new Booking { Id = 2, Flt = "ALT105", Kind = "ferry", From = "LSGG", To = "EGLF", Reg = "ZJ-ALU", TypeName = "Pilatus PC-12 NGX", DepAt = DateTime.UtcNow.AddHours(3) };
        _bookings.Items.Add(b1); _bookings.Items.Add(b2); _bookings.SelectedIndex = 0;
        _noBookings.Visible = false;
        _route.Text = "ALT104   EGJJ → LFPB";
        _sub.Text = "ZJ-ALT · Embraer Phenom 300E · 5 passengers";
        _phase.Text = "Taxiing in · park and set the brake";
        _phaseBar.Set(Phase.TaxiIn);
        _times.Text = "BLOCK 1:02   ·   AIR 0:51   ·   FLOWN 214 NM";
        _tGs.Set("14"); _tIas.Set("12"); _tAlt.Set("273"); _tVs.Set("0"); _tG.Set("1.00"); _tAtt.Set("+1/+0"); _tFuel.Set("2,410"); _tComfort.Set("96", Theme.Good);
        var res = JsonNode.Parse("{\"status\":\"accepted\",\"net\":14820,\"rep_delta\":3.5,\"points\":189,\"landing_score\":93,\"comfort_score\":96,\"note\":\"Butter landing, client tipped 5%. Smooth flight (comfort 96): extra 2% tip.\",\"stats\":{\"touchdown\":{\"runway\":\"27\",\"length_ft\":8858,\"td_ft\":1180,\"cl_m\":-1.4,\"cl_max_m\":2.6}}}");
        SetStat("Landing rate", "142 fpm", Theme.Good); SetStat("G at touchdown", "1.12 g"); SetStat("Bounces", "0");
        SetStat("Speed at touchdown", "108 kt IAS"); SetStat("Pitch at touchdown", "3.8°"); SetStat("Wind", "250° / 9 kt");
        ShowServerScore(res); ShowResult(res);
        _cabinTitle.Text = "CABIN CALL · SEAT 2B · MR WHITFORD";
        _cabinMsg.Text = "\"Could we have the champagne now, please?\"\nAnswer within 5 minutes.";
        _cabinBtns.Controls.Add(new FlatBtn("Of course, right away", true) { BackColor = Theme.Card2 });
        _cabinBtns.Controls.Add(new FlatBtn("After the seatbelt sign") { BackColor = Theme.Card2 });
        _cabin.Visible = true;
        Log("Block off at 13:02Z"); Log("Airborne at 13:11Z"); Log("Touchdown 142 fpm"); Log("Block on at 14:04Z");
        Application.DoEvents();
        PerformLayout(); Refresh(); Application.DoEvents();
        using var bmp = new Bitmap(Width, Height);
        DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
        bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _sim.Dispose();
        base.OnFormClosed(e);
    }
}
