// WinPrestige.exe: a small launcher that starts WinPrestige.ps1 (next to it) without a console window.
// The script asks for administrator rights itself, so this exe runs with normal rights.
// Built with the C# compiler that ships with Windows (.NET Framework 4); see build.ps1.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("WinPrestige")]
[assembly: AssemblyProduct("WinPrestige")]
[assembly: AssemblyDescription("Back up your apps and settings before a Windows reset, then restore them.")]
[assembly: AssemblyCompany("ohHeyItsCon")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Connor. MIT License.")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "WinPrestige.ps1");
        if (!File.Exists(script) || !Directory.Exists(Path.Combine(dir, "lib")))
        {
            MessageBox.Show(
                "WinPrestige.ps1 and the lib folder weren't found next to WinPrestige.exe.\n\n" +
                "Unzip the whole download and run WinPrestige.exe from that folder.",
                "WinPrestige", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");
        var arguments = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ");
        arguments.Append(Quote(script));
        arguments.Append(" -HideConsole");
        foreach (string a in args)
        {
            arguments.Append(' ');
            arguments.Append(Quote(a));
        }

        var psi = new ProcessStartInfo(powershell, arguments.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        try
        {
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Couldn't start PowerShell:\n" + ex.Message, "WinPrestige", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        return 0;
    }

    // Quotes one command-line argument the way Windows programs parse it back.
    static string Quote(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return s;
        var sb = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in s)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { sb.Append('\\', slashes * 2 + 1); sb.Append('"'); slashes = 0; continue; }
            sb.Append('\\', slashes);
            slashes = 0;
            sb.Append(c);
        }
        sb.Append('\\', slashes * 2);
        sb.Append('"');
        return sb.ToString();
    }
}
