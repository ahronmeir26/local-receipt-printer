using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

internal static class LocalReceiptPrinterKioskExit
{
    private const uint InvalidSessionId = 0xFFFFFFFF;

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSLogoffSession(
        IntPtr serverHandle,
        uint sessionId,
        bool wait
    );

    public static int Main()
    {
        uint sessionId = WTSGetActiveConsoleSessionId();
        if (sessionId == InvalidSessionId)
        {
            Console.Error.WriteLine("Windows has no active console session to exit.");
            return 2;
        }

        if (!WTSLogoffSession(IntPtr.Zero, sessionId, true))
        {
            int error = Marshal.GetLastWin32Error();
            Console.Error.WriteLine(
                "Windows could not sign out console session " + sessionId +
                ": " + new Win32Exception(error).Message + " (" + error + ")."
            );
            return 3;
        }

        Console.WriteLine(sessionId);
        return 0;
    }
}
