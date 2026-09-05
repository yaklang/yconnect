using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using YConnect.Core;

namespace YConnect.Views
{
    // The overview and widget share the same capability and copy paths.
    public sealed class ConnectionPanel
    {
        private readonly AppController controller;
        private readonly string prefix;
        private readonly Action changed;
        private readonly bool overview;
        private readonly Action newKey;
        private bool rendering;
        private string expanded = "", query = "";
        public string ExpandedSection => expanded;
        public ConnectionPanel(AppController controller, string prefix, Action changed, bool overview = false, Action newKey = null)
        { this.controller = controller; this.prefix = prefix; this.changed = changed; this.overview = overview; this.newKey = newKey ?? controller.NewKey; }
        private string Id(string name) => prefix + "-" + name;
        public FrameworkElement Render()
        {
            rendering = true;
            var store = controller.Store;
            var share = Ui.SmallButton(controller.CopyLabel("share", "复制接入信息"), Id("copy-access"), () => controller.CopyAccess(), "Primary");
            share.Width = 94; share.MinHeight = 30; share.ToolTip = "包含当前 Key、模型与接入地址，请仅交给可信的人"; share.IsEnabled = store.CurrentKey != null;
            var panel = Ui.Stack(Ui.Between(Ui.Label("当前连接", 13, "Ink", true), share), Ui.Gap(10));
            FrameworkElement selection;
            if (store.Mode == "account")
            {
                var choices = store.Keys.Where(k => k.Flag("active")).Select(k => new KeyChoice { Id = (long)k["id"], Label = k.Text("label") + " · •••• " + k.Text("last4") }).ToArray();
                var keys = Ui.Id(new ComboBox { ItemsSource = choices, SelectedItem = choices.FirstOrDefault(k => k.Id == store.Preferences.SelectedKey), MinHeight = 36, IsEnabled = !store.Busy }, Id("key-select"));
                keys.SelectionChanged += async (s, e) => { if (!rendering && keys.SelectedItem is KeyChoice key) await store.Run(() => store.SelectKey(key.Id)); };
                selection = keys;
            }
            else selection = Ui.Card(Ui.Label(store.DisplayName + " · •••• " + store.KeyInfo?["key"].Text("last4"), 12), 9, "SurfaceAlt");
            var copy = Ui.SmallButton(controller.CopyLabel("key", "复制 Key"), Id("copy-key"), controller.CopyKey);
            copy.Width = 66; copy.MinHeight = 36; copy.IsEnabled = store.CurrentKey != null; copy.Margin = new Thickness(6, 0, 0, 0);
            var actions = Ui.Row(copy);
            if (store.Mode == "account") actions.Children.Add(Ui.IconButton("\uE710", "新增 API Key", Id("new-key"), newKey));
            panel.Children.Add(Ui.Between(selection, actions));
            panel.Children.Add(Ui.Divider());
            panel.Children.Add(Disclosure("协议接入地址", "protocols"));
            if (expanded == "protocols")
            {
                var urls = Ui.Stack();
                foreach (var endpoint in AppController.Endpoints)
                {
                    var item = endpoint;
                    var copyUrl = Ui.SmallButton(controller.CopyLabel(item.Id, "复制"), overview ? Id("endpoint-" + item.Id) : "endpoint-" + item.Id, () => controller.CopyEndpoint(item.Id));
                    copyUrl.Width = 64; copyUrl.MinHeight = 30;
                    var label = Ui.Stack(Ui.Label(item.Label, 11, "Muted", true), Ui.Gap(4), Ui.Selectable(item.Url, 11));
                    var line = Ui.Between(label, copyUrl); line.Margin = new Thickness(8, 7, 0, 7); urls.Children.Add(line);
                }
                panel.Children.Add(urls);
            }
            panel.Children.Add(Ui.Divider());
            if (overview)
            {
                panel.Children.Add(Ui.Between(Ui.Label("模型", 13, "Ink", true), Ui.Label(store.Models.Count + " 个可用", 11, "Muted")));
                panel.Children.Add(Ui.Gap(8)); panel.Children.Add(SearchModels(174));
            }
            else
            {
                panel.Children.Add(Disclosure("模型 · " + store.Models.Count, "models"));
                if (expanded == "models") { panel.Children.Add(Ui.Gap(6)); panel.Children.Add(SearchModels(192)); }
                else foreach (var model in store.FrequentModels) panel.Children.Add(ModelRow(model, false));
            }
            if (store.Models.Count == 0) panel.Children.Add(Ui.Text("当前暂无可用模型，请刷新连接。", 12, "Muted"));
            rendering = false;
            return Ui.Card(panel, overview ? 16 : 12);
        }
        private Button Disclosure(string text, string destination)
        {
            var button = Ui.Button("", Id(destination), () => { expanded = expanded == destination ? "" : destination; changed(); }, "ActionRow");
            button.Content = Ui.Between(Ui.Label(text, 12, "Ink", true), Ui.Glyph(expanded == destination ? "\uE70E" : "\uE70D", 10));
            if (expanded == destination) button.SetResourceReference(Control.BackgroundProperty, "SurfaceAlt");
            return button;
        }
        private FrameworkElement SearchModels(double maxHeight)
        {
            var store = controller.Store;
            var input = Ui.Id(new TextBox { Text = query, FontSize = 12, MinHeight = 34, Padding = new Thickness(10, 7, 10, 7) }, Id("model-search"));
            input.ToolTip = "搜索模型名称、ID 或协议";
            var results = Ui.Stack();
            Action update = () =>
            {
                results.Children.Clear();
                var models = store.Models.Where(m => (m.Name + " " + m.Id + " " + string.Join(" ", m.Protocols)).IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0).ToArray();
                foreach (var model in models) results.Children.Add(ModelRow(model, true));
                if (models.Length == 0) results.Children.Add(Ui.Text("没有匹配的模型", 12, "Muted"));
            };
            input.TextChanged += (s, e) => { query = input.Text; update(); }; update();
            return Ui.Stack(Ui.SearchField(input, "搜索模型名称、ID 或协议"), Ui.Gap(6), new ScrollViewer { Content = results, MaxHeight = maxHeight });
        }
        private FrameworkElement ModelRow(AvailableModel model, bool detail)
        {
            var selected = controller.Store.Preferences.CurrentModel == model.Id;
            var choose = Ui.Button("", Id("model-select-" + model.Id), () => controller.Store.RememberModel(model.Id), "ActionRow");
            choose.Padding = new Thickness(8, 5, 6, 5); choose.MinHeight = detail ? 42 : 32;
            var indicator = Ui.Label(selected ? "✓" : "", 11, "Accent", true);
            var name = Ui.Label(model.Name, 12, selected ? "Accent" : "Ink", selected); name.ToolTip = model.Name;
            var label = detail ? (UIElement)Ui.Stack(name, Ui.Gap(3), Ui.Label(model.Id, 10, "Muted")) : name;
            choose.Content = Ui.IconLabel(indicator, label, 12, 5);
            var copy = Ui.SmallButton(controller.CopyLabel("model:" + model.Id, "复制 ID"), Id("model-" + model.Id), () => controller.CopyModelId(model.Id));
            copy.Width = 62; copy.MinHeight = 32; copy.FontSize = 11; copy.Foreground = Ui.Brush("Muted");
            return Ui.Between(choose, copy);
        }
        private sealed class KeyChoice { public long Id; public string Label; public override string ToString() => Label; }
    }
}
