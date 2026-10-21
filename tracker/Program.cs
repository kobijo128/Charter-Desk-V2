namespace CharterDeskTracker;

static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        var args = Environment.GetCommandLineArgs();
        int i = Array.IndexOf(args, "--screenshot");
        if (i > 0 && i + 1 < args.Length)
        {
            // build check: render the window with sample data to a PNG and exit
            MainForm.Demo = true;
            using var f = new MainForm { StartPosition = FormStartPosition.Manual, Location = new System.Drawing.Point(0, 0), ShowInTaskbar = false };
            f.Shown += (_, _) => { f.SaveDemoScreenshot(args[i + 1]); f.Close(); };
            Application.Run(f);
            return;
        }
        Application.Run(new MainForm());
    }
}
