using System.Text.Json.Nodes;

namespace CharterDeskTracker;

public enum Phase { Waiting, TaxiOut, TakeoffRoll, Climb, Cruise, Descent, Landed, TaxiIn, Arrived }

/// <summary>
/// Turns a stream of sim samples into a flight: phases, block times, landing quality and checks.
/// Feed it about four samples a second with Update().
/// </summary>
public sealed class FlightRecorder
{
    public Booking Booking { get; }
    public Phase Phase { get; private set; } = Phase.Waiting;
    public string Sim { get; set; } = "";
    public string AircraftTitle { get; private set; } = "";

    public DateTime? BlockOff, Takeoff, Landing, BlockOn;
    public double DepLat, DepLon, ArrLat, ArrLon;
    public double? LandingFpm, LandingG;
    public int Bounces;
    public double DistanceNm;
    public double MaxSimRate = 1;
    public bool SlewSeen, CrashSeen;
    public double OverspeedSeconds;
    public double FuelStart, FuelEnd;
    public double MaxAltFt;

    // what the passengers felt (seconds or counts), sent with the report and scored by the server
    public double GSeconds, BankSeconds, PitchSeconds, SteepDescentSeconds, TaxiFastSeconds;
    public int HardBrakes;
    public double MaxBank, MaxPitchUp, MaxPitchDown, MaxG = 1, MinG = 1, MaxDescentFpm;

    // the moment of touchdown and the first part of the rollout, for runway and centreline analysis
    public Sample TouchdownSample;
    readonly List<double[]> _rollout = new();
    DateTime _lastRolloutPoint = DateTime.MinValue;
    DateTime _brakeCooldown = DateTime.MinValue;

    /// <summary>The same comfort formula the server uses, so the live figure matches the report.</summary>
    public int ComfortScore
    {
        get
        {
            double s = 100;
            s -= Math.Min(25, GSeconds * 0.5);
            s -= Math.Min(20, BankSeconds);
            if (MaxBank > 45) s -= 10;
            s -= Math.Min(15, PitchSeconds);
            s -= Math.Min(10, SteepDescentSeconds * 0.3);
            s -= Math.Min(10, TaxiFastSeconds * 0.5);
            s -= Math.Min(12, HardBrakes * 4);
            return (int)Math.Round(Math.Clamp(s, 0, 100));
        }
    }

    /// <summary>Rough landing score from what the tracker knows (the server adds runway accuracy).</summary>
    public int? LandingScoreEstimate
    {
        get
        {
            if (LandingFpm == null) return null;
            double f = LandingFpm.Value, s = 100;
            s -= f < 50 ? 8 : f <= 180 ? 0 : f <= 300 ? (f - 180) / 6 : f <= 450 ? 20 + (f - 300) / 5 : f <= 600 ? 50 + (f - 450) / 7.5 : 80;
            if (LandingG > 1.35) s -= Math.Min(25, (LandingG.Value - 1.35) * 50);
            s -= 12 * Math.Min(Bounces, 4);
            if (TouchdownSample != null && TouchdownSample.PitchDeg < -0.5) s -= 15;
            return (int)Math.Round(Math.Clamp(s, 0, 100));
        }
    }

    readonly List<double[]> _path = new();
    Sample _last;
    DateTime _lastPathPoint = DateTime.MinValue;
    DateTime? _touchdownAt, _stoppedSince, _airborneSince;
    double _lastAirborneVs;

    public event Action<string> Log;
    public event Action Arrived;

    public FlightRecorder(Booking booking) { Booking = booking; }

    public void Update(Sample s)
    {
        if (s.Paused) { _last = s; return; }
        if (!string.IsNullOrEmpty(s.Title)) AircraftTitle = s.Title;

        // integrity tracking, only while the flight is actually under way
        if (Phase != Phase.Waiting && Phase != Phase.Arrived)
        {
            MaxSimRate = Math.Max(MaxSimRate, s.SimRate);
            if (s.Slew) SlewSeen = true;
            if (s.Crashed) CrashSeen = true;
            TrackComfort(s);
            if (!s.OnGround && s.AltFt < 10000 && s.IasKt > 255 && _last != null)
                OverspeedSeconds += (s.Utc - _last.Utc).TotalSeconds;
            if (_last != null && s.GsKt > 2)
            {
                var d = Geo.Nm(_last.Lat, _last.Lon, s.Lat, s.Lon);
                if (d < 5) DistanceNm += d; // ignore teleports; slew flag catches those
            }
            if ((s.Utc - _lastPathPoint).TotalSeconds >= (s.OnGround ? 20 : 30) && _path.Count < 3900)
            {
                _path.Add(new[] { Math.Round(s.Lat, 5), Math.Round(s.Lon, 5), Math.Round(s.AltFt) });
                _lastPathPoint = s.Utc;
            }
        }
        if (!s.OnGround) _lastAirborneVs = s.VsFpm;

        switch (Phase)
        {
            case Phase.Waiting:
                if (s.OnGround && s.GsKt > 3)
                {
                    BlockOff = s.Utc; DepLat = s.Lat; DepLon = s.Lon; FuelStart = s.FuelLb;
                    SetPhase(Phase.TaxiOut, $"Block off at {s.Utc:HH:mm}Z");
                }
                break;

            case Phase.TaxiOut:
                if (s.OnGround && s.GsKt > 40) SetPhase(Phase.TakeoffRoll, "Takeoff roll");
                else if (!s.OnGround) Liftoff(s);
                break;

            case Phase.TakeoffRoll:
                if (!s.OnGround) Liftoff(s);
                else if (s.GsKt < 25) SetPhase(Phase.TaxiOut, "Rejected takeoff or back to taxi");
                break;

            case Phase.Climb:
            case Phase.Cruise:
            case Phase.Descent:
                if (s.OnGround) { Touchdown(s); break; }
                var next = s.VsFpm > 400 ? Phase.Climb : s.VsFpm < -400 ? Phase.Descent : Phase.Cruise;
                if (next != Phase) SetPhase(next, null);
                break;

            case Phase.Landed:
                if (!s.OnGround)
                {
                    _airborneSince ??= s.Utc;
                    // airborne again for a while: treat as a go-around or touch-and-go
                    if ((s.Utc - _airborneSince.Value).TotalSeconds > 20)
                    {
                        Landing = null; LandingFpm = null; LandingG = null; Bounces = 0; _touchdownAt = null; TouchdownSample = null; _rollout.Clear();
                        SetPhase(Phase.Climb, "Go-around");
                    }
                    break;
                }
                if (_airborneSince != null) { Bounces++; _airborneSince = null; Log?.Invoke($"Bounce {Bounces}"); }
                if (_touchdownAt != null && (s.Utc - _touchdownAt.Value).TotalSeconds < 3)
                    LandingG = Math.Max(LandingG ?? 0, s.G);
                if (s.GsKt < 30) SetPhase(Phase.TaxiIn, "Taxiing in");
                break;

            case Phase.TaxiIn:
                bool parked = s.OnGround && s.GsKt < 1 && (s.ParkingBrake || !s.EnginesRunning);
                if (!parked) { _stoppedSince = null; if (!s.OnGround) SetPhase(Phase.Climb, "Airborne again"); break; }
                _stoppedSince ??= s.Utc;
                if ((s.Utc - _stoppedSince.Value).TotalSeconds >= 5)
                {
                    BlockOn = s.Utc; ArrLat = s.Lat; ArrLon = s.Lon; FuelEnd = s.FuelLb;
                    _path.Add(new[] { Math.Round(s.Lat, 5), Math.Round(s.Lon, 5), Math.Round(s.AltFt) });
                    SetPhase(Phase.Arrived, $"Block on at {s.Utc:HH:mm}Z");
                    Arrived?.Invoke();
                }
                break;
        }
        _last = s;
    }

    void TrackComfort(Sample s)
    {
        if (_last == null) return;
        var dt = Math.Clamp((s.Utc - _last.Utc).TotalSeconds, 0, 2);
        MaxAltFt = Math.Max(MaxAltFt, s.AltFt);
        bool airborne = !s.OnGround && Phase is Phase.Climb or Phase.Cruise or Phase.Descent;
        if (airborne)
        {
            if (Math.Abs(s.G - 1) > 0.25) GSeconds += dt;
            MaxG = Math.Max(MaxG, s.G); MinG = Math.Min(MinG, s.G);
            var bank = Math.Abs(s.BankDeg);
            if (bank > 30) BankSeconds += dt;
            MaxBank = Math.Max(MaxBank, bank);
            if (s.PitchDeg > 18 || s.PitchDeg < -8) PitchSeconds += dt;
            MaxPitchUp = Math.Max(MaxPitchUp, s.PitchDeg); MaxPitchDown = Math.Min(MaxPitchDown, s.PitchDeg);
            if (s.VsFpm < -3500) SteepDescentSeconds += dt;
            MaxDescentFpm = Math.Min(MaxDescentFpm, s.VsFpm);
        }
        bool taxiing = s.OnGround && Phase is Phase.TaxiOut or Phase.TaxiIn;
        if (taxiing)
        {
            if (s.GsKt > 30) TaxiFastSeconds += dt;
            // a sharp stop: losing more than 4 kt a second below 40 kt
            if (dt > 0.1 && _last.GsKt < 40 && (_last.GsKt - s.GsKt) / dt > 4 && s.Utc > _brakeCooldown)
            {
                HardBrakes++; _brakeCooldown = s.Utc.AddSeconds(5);
                Log?.Invoke("Sharp braking on the taxiway");
            }
        }
        // rollout trace: every half second while still fast, for the first minute after touchdown
        if (_touchdownAt != null && s.OnGround && s.GsKt > 35 && (s.Utc - _touchdownAt.Value).TotalSeconds < 60 &&
            (s.Utc - _lastRolloutPoint).TotalSeconds >= 0.5 && _rollout.Count < 150)
        {
            _rollout.Add(new[] { Math.Round(s.Lat, 6), Math.Round(s.Lon, 6) });
            _lastRolloutPoint = s.Utc;
        }
    }

    void Liftoff(Sample s)
    {
        Takeoff ??= s.Utc;
        SetPhase(Phase.Climb, $"Airborne at {s.Utc:HH:mm}Z");
    }

    void Touchdown(Sample s)
    {
        if (Landing == null)
        {
            Landing = s.Utc;
            _touchdownAt = s.Utc;
            // FSUIPC holds the last airborne vertical speed in 0x030C; fall back to our own sample
            var fpm = Math.Abs(s.TouchdownVsFpm) > 1 ? s.TouchdownVsFpm : _lastAirborneVs;
            LandingFpm = Math.Round(Math.Abs(fpm));
            LandingG = s.G;
            TouchdownSample = s;
            _rollout.Clear();
            Log?.Invoke($"Touchdown {LandingFpm:0} fpm");
        }
        _airborneSince = null;
        SetPhase(Phase.Landed, null);
    }

    void SetPhase(Phase p, string message)
    {
        if (p == Phase) return;
        Phase = p;
        Log?.Invoke(message ?? p.ToString());
    }

    public JsonObject BuildReport(string trackerVersion)
    {
        var path = new JsonArray();
        foreach (var p in _path) path.Add(new JsonArray(p[0], p[1], p[2]));
        return new JsonObject
        {
            ["sim"] = Sim,
            ["aircraft_title"] = AircraftTitle,
            ["tracker_ver"] = trackerVersion,
            ["block_off"] = BlockOff?.ToString("o"),
            ["takeoff"] = Takeoff?.ToString("o") ?? "",
            ["landing"] = Landing?.ToString("o") ?? "",
            ["block_on"] = BlockOn?.ToString("o"),
            ["dep_lat"] = DepLat, ["dep_lon"] = DepLon,
            ["arr_lat"] = ArrLat, ["arr_lon"] = ArrLon,
            ["landing_fpm"] = LandingFpm,
            ["landing_g"] = LandingG.HasValue ? (double?)Math.Round(LandingG.Value, 2) : null,
            ["bounces"] = Bounces,
            ["fuel_used_lb"] = Math.Round(Math.Max(0, FuelStart - FuelEnd)),
            ["fuel_on_block_lb"] = Math.Round(FuelEnd),
            ["dist_flown"] = Math.Round(DistanceNm),
            ["max_sim_rate"] = Math.Round(MaxSimRate, 2),
            ["overspeed_s"] = (int)OverspeedSeconds,
            ["crashed"] = CrashSeen,
            ["slew"] = SlewSeen,
            ["path"] = path,
            ["max_alt_ft"] = Math.Round(MaxAltFt),
            ["touchdown"] = TouchdownSample == null ? null : new JsonObject
            {
                ["lat"] = Math.Round(TouchdownSample.Lat, 6), ["lon"] = Math.Round(TouchdownSample.Lon, 6),
                ["hdg_true"] = Math.Round(TouchdownSample.HdgTrue, 1),
                ["ias"] = Math.Round(TouchdownSample.IasKt), ["gs"] = Math.Round(TouchdownSample.GsKt),
                ["pitch"] = Math.Round(TouchdownSample.PitchDeg, 1), ["bank"] = Math.Round(TouchdownSample.BankDeg, 1),
                ["wind_dir"] = Math.Round(TouchdownSample.WindDir), ["wind_kt"] = Math.Round(TouchdownSample.WindKt)
            },
            ["rollout"] = Rollout(),
            ["comfort"] = new JsonObject
            {
                ["g_s"] = Math.Round(GSeconds, 1), ["bank_s"] = Math.Round(BankSeconds, 1), ["pitch_s"] = Math.Round(PitchSeconds, 1),
                ["vs_s"] = Math.Round(SteepDescentSeconds, 1), ["taxi_fast_s"] = Math.Round(TaxiFastSeconds, 1), ["hard_brake_n"] = HardBrakes,
                ["max_bank"] = Math.Round(MaxBank, 1), ["max_pitch_up"] = Math.Round(MaxPitchUp, 1), ["max_pitch_down"] = Math.Round(MaxPitchDown, 1),
                ["max_g"] = Math.Round(MaxG, 2), ["min_g"] = Math.Round(MinG, 2), ["max_descent_fpm"] = Math.Round(MaxDescentFpm)
            }
        };
    }

    JsonArray Rollout()
    {
        var a = new JsonArray();
        foreach (var p in _rollout) a.Add(new JsonArray(p[0], p[1]));
        return a;
    }
}

public static class Geo
{
    public static double Nm(double lat1, double lon1, double lat2, double lon2)
    {
        const double r = Math.PI / 180;
        var a = Math.Pow(Math.Sin((lat2 - lat1) * r / 2), 2) +
                Math.Cos(lat1 * r) * Math.Cos(lat2 * r) * Math.Pow(Math.Sin((lon2 - lon1) * r / 2), 2);
        return 2 * 3440.065 * Math.Asin(Math.Min(1, Math.Sqrt(a)));
    }
}
