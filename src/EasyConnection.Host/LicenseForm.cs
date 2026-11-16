using System.Drawing;

namespace EasyConnection.Host;

internal sealed class LicenseForm : Form
{
    public LicenseForm()
    {
        Text = "EasyConnection · 开源许可证";
        ClientSize = new Size(800, 600);
        ShowIcon = false;
        ShowInTaskbar = false;
        var tabs = new TabControl { Dock = DockStyle.Fill };
        Controls.Add(tabs);
        Add("MIT 许可证", "EasyConnection.License");
        Add("第三方声明", "EasyConnection.ThirdPartyNotices");
        void Add(string title, string resource)
        {
            var page = new TabPage(title);
            page.Controls.Add(new TextBox { Text = Branding.LicenseText(resource).ReplaceLineEndings("\r\n"), ReadOnly = true, Multiline = true,
                Dock = DockStyle.Fill, ScrollBars = ScrollBars.Both, WordWrap = false, Font = new Font("Consolas", 10) });
            tabs.TabPages.Add(page);
        }
    }
}
