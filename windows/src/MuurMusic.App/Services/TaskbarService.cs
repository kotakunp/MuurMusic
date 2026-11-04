using System.Drawing;
using System.Runtime.InteropServices;
using MuurMusic.Audio.Playback;

namespace MuurMusic.App.Services;

/// <summary>
/// Taskbar thumbnail toolbar (previous / play-pause / next) via the Win32 ITaskbarList3 COM interface
/// plus a window subclass that receives the button clicks as WM_COMMAND. Also drives taskbar progress.
/// </summary>
public sealed class TaskbarService : IDisposable
{
    private const uint WmCommand = 0x0111;
    private const int ThbnClicked = 0x1800;
    private const uint BtnPrevious = 1001, BtnPlayPause = 1002, BtnNext = 1003;

    private readonly IPlaybackService _playback;
    private IntPtr _hwnd;
    private ITaskbarList3? _taskbar;
    private SubclassProc? _subclass;
    private IntPtr _iconPrev, _iconPlay, _iconPause, _iconNext;
    private bool _buttonsAdded;
    private bool _showingPlay;

    public TaskbarService(IPlaybackService playback) => _playback = playback;

    public void Initialize(IntPtr hwnd)
    {
        _hwnd = hwnd;
        try
        {
            _iconPrev = CreateGlyphIcon("\uE892");
            _iconPlay = CreateGlyphIcon("\uE768");
            _iconPause = CreateGlyphIcon("\uE769");
            _iconNext = CreateGlyphIcon("\uE893");
            var type = Type.GetTypeFromCLSID(new Guid("56FDF344-FD6D-11d0-958A-006097C9A090"))
                       ?? throw new InvalidOperationException("TaskbarList CLSID not found");
            _taskbar = (ITaskbarList3?)Activator.CreateInstance(type) ?? throw new InvalidOperationException("Could not create ITaskbarList3");
            _taskbar.HrInit();
            AddButtons();
            _subclass = WndProc;
            SetWindowSubclass(hwnd, _subclass, new IntPtr(1), IntPtr.Zero);
            _playback.StateChanged += (_, _) => UpdatePlayPauseIcon();
        }
        catch (Exception)
        {
            _taskbar = null; // taskbar buttons are a nicety; never break the app over them
        }
    }

    private void AddButtons()
    {
        if (_taskbar is null || _buttonsAdded) return;
        var buttons = new[]
        {
            new THUMBBUTTON { dwMask = THBMASK.ICON | THBMASK.TOOLTIP | THBMASK.FLAGS, iId = BtnPrevious, hIcon = _iconPrev, szTip = "Previous", dwFlags = THBFLAGS.ENABLED },
            new THUMBBUTTON { dwMask = THBMASK.ICON | THBMASK.TOOLTIP | THBMASK.FLAGS, iId = BtnPlayPause, hIcon = _iconPlay, szTip = "Play", dwFlags = THBFLAGS.ENABLED },
            new THUMBBUTTON { dwMask = THBMASK.ICON | THBMASK.TOOLTIP | THBMASK.FLAGS, iId = BtnNext, hIcon = _iconNext, szTip = "Next", dwFlags = THBFLAGS.ENABLED },
        };
        _taskbar.ThumbBarAddButtons(_hwnd, (uint)buttons.Length, buttons);
        _buttonsAdded = true;
    }

    public void UpdatePlayPauseIcon()
    {
        var playing = _playback.State == PlayerState.Playing || _playback.State == PlayerState.Buffering;
        _showingPlay = playing;
        var b = new THUMBBUTTON
        {
            dwMask = THBMASK.ICON | THBMASK.TOOLTIP | THBMASK.FLAGS,
            iId = BtnPlayPause,
            hIcon = playing ? _iconPause : _iconPlay,
            szTip = playing ? "Pause" : "Play",
            dwFlags = THBFLAGS.ENABLED,
        };
        try { _taskbar?.ThumbBarUpdateButtons(_hwnd, 1, new[] { b }); } catch (COMException) { }
    }

    /// <summary>
    /// Adds Resume/Pause entries to the taskbar jump list. Jump lists require a packaged identity;
    /// when the app runs unpackaged this no-ops silently (that is fine — the thumbnail buttons still work).
    /// </summary>
    public async Task TryInitializeJumpListAsync()
    {
        try
        {
            if (!Windows.UI.StartScreen.JumpList.IsSupported()) return;
            var list = await Windows.UI.StartScreen.JumpList.LoadCurrentAsync();
            list.SystemGroupKind = Windows.UI.StartScreen.JumpListSystemGroupKind.Recent;
            list.Items.Clear();
            list.Items.Add(Windows.UI.StartScreen.JumpListItem.CreateWithArguments("--play-pause", "Play / pause"));
            list.Items[^1].Logo = new Uri("ms-appx:///Assets/AppLogo.png");
            list.Items.Add(Windows.UI.StartScreen.JumpListItem.CreateWithArguments("--next", "Next track"));
            list.Items[^1].Logo = new Uri("ms-appx:///Assets/AppLogo.png");
            list.Items.Add(Windows.UI.StartScreen.JumpListItem.CreateWithArguments("--previous", "Previous track"));
            list.Items[^1].Logo = new Uri("ms-appx:///Assets/AppLogo.png");
            await list.SaveAsync();
        }
        catch (Exception)
        {
            // No package identity (unpackaged run) or jump lists disabled: skip gracefully.
        }
    }

    /// <summary>Taskbar progress bar mirroring playback position (call ~2-4 Hz).</summary>
    public void UpdateProgress(TimeSpan position, TimeSpan duration, PlayerState state)
    {
        if (_taskbar is null) return;
        try
        {
            if (state != PlayerState.Playing && state != PlayerState.Paused || duration.TotalSeconds < 1)
            {
                _taskbar.SetProgressState(_hwnd, state == PlayerState.Paused ? TBPFLAG.PAUSED : TBPFLAG.NOPROGRESS);
                return;
            }
            _taskbar.SetProgressState(_hwnd, TBPFLAG.NORMAL);
            _taskbar.SetProgressValue(_hwnd, (ulong)Math.Max(0, position.TotalSeconds), (ulong)Math.Ceiling(duration.TotalSeconds));
        }
        catch (COMException) { }
    }

    private IntPtr WndProc(IntPtr hWnd, uint uMsg, IntPtr wParam, IntPtr lParam, IntPtr uIdSubclass, IntPtr dwRefData)
    {
        if (uMsg == WmCommand && (int)((long)wParam >> 16) == ThbnClicked)
        {
            var id = (uint)((long)wParam & 0xFFFF);
            var dq = App.CurrentWindow?.DispatcherQueue;
            void Enqueue(Func<Task> a) { if (dq is not null) dq.TryEnqueue(async () => await a().ConfigureAwait(false)); else _ = a(); }
            switch (id)
            {
                case BtnPrevious: Enqueue(() => _playback.PreviousAsync()); break;
                case BtnPlayPause: Enqueue(() => _playback.TogglePlayPauseAsync()); break;
                case BtnNext: Enqueue(() => _playback.NextAsync()); break;
            }
            return IntPtr.Zero;
        }
        return DefSubclassProc(hWnd, uMsg, wParam, lParam);
    }

    private static IntPtr CreateGlyphIcon(string glyph)
    {
        const int size = 20;
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(System.Drawing.Color.Transparent);
            using var font = new Font("Segoe MDL2 Assets", 13f, GraphicsUnit.Pixel);
            using var brush = new SolidBrush(System.Drawing.Color.White);
            var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
            g.DrawString(glyph, font, brush, new RectangleF(0, 0, size, size), fmt);
        }
        var hIcon = bmp.GetHicon();
        return hIcon;
    }

    public void Dispose()
    {
        try
        {
            if (_hwnd != IntPtr.Zero && _subclass is not null) RemoveWindowSubclass(_hwnd, _subclass, new IntPtr(1));
            foreach (var h in new[] { _iconPrev, _iconPlay, _iconPause, _iconNext })
                if (h != IntPtr.Zero) DestroyIcon(h);
        }
        catch (Exception) { }
    }

    private delegate IntPtr SubclassProc(IntPtr hWnd, uint uMsg, IntPtr wParam, IntPtr lParam, IntPtr uIdSubclass, IntPtr dwRefData);

    [DllImport("comctl32.dll", SetLastError = true)] private static extern bool SetWindowSubclass(IntPtr hWnd, SubclassProc pfnSubclass, IntPtr uIdSubclass, IntPtr dwRefData);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(IntPtr hWnd, SubclassProc pfnSubclass, IntPtr uIdSubclass);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr hWnd, uint uMsg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr hIcon);

    private enum TBPFLAG { NOPROGRESS = 0, INDETERMINATE = 1, NORMAL = 2, ERROR = 4, PAUSED = 8 }
    [Flags] private enum THBMASK : uint { BITMAP = 0x1, ICON = 0x2, TOOLTIP = 0x4, FLAGS = 0x8 }
    [Flags] private enum THBFLAGS : uint { ENABLED = 0x0, DISABLED = 0x1, DISMISSONCLICK = 0x2, NOBACKGROUND = 0x4, HIDDEN = 0x8, NONINTERACTIVE = 0x10 }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 8)]
    private struct THUMBBUTTON
    {
        public THBMASK dwMask;
        public uint iId;
        public uint iBitmap;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szTip;
        public THBFLAGS dwFlags;
    }

    [ComImport, Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITaskbarList3
    {
        void HrInit();
        void AddTab(IntPtr hwnd);
        void DeleteTab(IntPtr hwnd);
        void ActivateTab(IntPtr hwnd);
        void SetActiveAlt(IntPtr hwnd);
        void MarkFullscreenWindow([MarshalAs(UnmanagedType.Bool)] bool fFullscreen);
        void SetProgressValue(IntPtr hwnd, ulong ullCompleted, ulong ullTotal);
        void SetProgressState(IntPtr hwnd, TBPFLAG tbpFlags);
        void RegisterTab(IntPtr hwndTab, IntPtr hwndMDI);
        void UnregisterTab(IntPtr hwndTab);
        void SetTabOrder(IntPtr hwndTab, IntPtr hwndInsertBefore);
        void SetTabActive(IntPtr hwndTab, IntPtr hwndMDI, uint dwReserved);
        void ThumbBarAddButtons(IntPtr hwnd, uint cButtons, [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] THUMBBUTTON[] pButton);
        void ThumbBarUpdateButtons(IntPtr hwnd, uint cButtons, [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] THUMBBUTTON[] pButton);
        void ThumbBarSetImageList(IntPtr hwnd, IntPtr himl);
        void SetOverlayIcon(IntPtr hwnd, IntPtr hIcon, [MarshalAs(UnmanagedType.LPWStr)] string pszDescription);
        void SetThumbnailTooltip(IntPtr hwnd, [MarshalAs(UnmanagedType.LPWStr)] string pszTip);
        void SetThumbnailClip(IntPtr hwnd, IntPtr prcClip);
    }
}
