using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace Tukevejtso
{
    // Windows Common Item Dialog in folder-picking mode. No folder is accepted
    // until the user presses Select folder; Cancel returns null.
    public static class PdfFolderPicker
    {
        [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
        private class FileOpenDialog { }

        [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"),
         InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFileDialog
        {
            [PreserveSig] int Show(IntPtr owner);
            void SetFileTypes(uint count, IntPtr filters);
            void SetFileTypeIndex(uint index);
            void GetFileTypeIndex(out uint index);
            void Advise(IntPtr events, out uint cookie);
            void Unadvise(uint cookie);
            void SetOptions(uint options);
            void GetOptions(out uint options);
            void SetDefaultFolder(IShellItem folder);
            void SetFolder(IShellItem folder);
            void GetFolder(out IShellItem folder);
            void GetCurrentSelection(out IShellItem item);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
            void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            void GetResult(out IShellItem item);
            void AddPlace(IShellItem item, uint location);
            void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
            void Close(int result);
            void SetClientGuid(ref Guid guid);
            void ClearClientData();
            void SetFilter(IntPtr filter);
        }

        [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"),
         InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem
        {
            void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
            void GetParent(out IShellItem parent);
            void GetDisplayName(uint kind, out IntPtr name);
            void GetAttributes(uint mask, out uint attributes);
            void Compare(IShellItem other, uint hint, out int order);
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(
            string path, IntPtr context, ref Guid iid, out IShellItem item);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();

        public static string Show(string initialFolder)
        {
            // powershell.exe -STA is used by tk. Support a direct MTA caller too.
            if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA)
                return ShowCore(initialFolder);

            string selected = null;
            Exception failure = null;
            Thread thread = new Thread(delegate()
            {
                try { selected = ShowCore(initialFolder); }
                catch (Exception exception) { failure = exception; }
            });
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            thread.Join();
            if (failure != null) throw new InvalidOperationException("Windows folder selection failed.", failure);
            return selected;
        }

        private static string ShowCore(string initialFolder)
        {
            IFileDialog dialog = null;
            IShellItem start = null;
            IShellItem result = null;
            IntPtr name = IntPtr.Zero;
            try
            {
                dialog = (IFileDialog)new FileOpenDialog();
                uint options;
                dialog.GetOptions(out options);
                // PICKFOLDERS | FORCEFILESYSTEM | PATHMUSTEXIST | DONTADDTORECENT.
                dialog.SetOptions(options | 0x20u | 0x40u | 0x800u | 0x02000000u);
                dialog.SetTitle("PDF Join - Choose a folder");
                dialog.SetOkButtonLabel("Select folder");
                Guid client = new Guid("13F1DACA-641C-4CD5-8BD2-41BC12DDE818");
                dialog.SetClientGuid(ref client);
                if (!String.IsNullOrWhiteSpace(initialFolder) && Directory.Exists(initialFolder))
                {
                    Guid iid = typeof(IShellItem).GUID;
                    SHCreateItemFromParsingName(initialFolder, IntPtr.Zero, ref iid, out start);
                    // The last explicitly chosen folder is only the starting view.
                    dialog.SetFolder(start);
                }
                int status = dialog.Show(GetConsoleWindow());
                if (status == unchecked((int)0x800704C7)) return null; // Cancel
                Marshal.ThrowExceptionForHR(status);
                dialog.GetResult(out result);
                result.GetDisplayName(0x80058000, out name); // SIGDN_FILESYSPATH
                return Marshal.PtrToStringUni(name);
            }
            finally
            {
                if (name != IntPtr.Zero) Marshal.FreeCoTaskMem(name);
                if (result != null) Marshal.ReleaseComObject(result);
                if (start != null) Marshal.ReleaseComObject(start);
                if (dialog != null) Marshal.ReleaseComObject(dialog);
            }
        }
    }
}
