using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace YConnect.Views
{
    public sealed class DialogWindow : Window
    {
        public DialogWindow(Window owner, string title, UIElement body, string action = "确认", bool danger = false)
        {
            Title = title; Owner = owner; Width = 560; MaxHeight = Math.Max(450, SystemParameters.WorkArea.Height - 60); SizeToContent = SizeToContent.Height; WindowStartupLocation = WindowStartupLocation.CenterOwner; ResizeMode = ResizeMode.NoResize; WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; ShowInTaskbar = false;
            var cancel = Ui.Button("取消", "dialog-cancel", () => { DialogResult = false; }); var confirm = Ui.Button(action, "dialog-confirm", () => { DialogResult = true; }, "Primary"); confirm.Margin = new Thickness(10, 0, 0, 0);
            if (danger) confirm.SetResourceReference(Control.BackgroundProperty, "Danger");
            var buttons = Ui.Row(cancel, confirm); buttons.HorizontalAlignment = HorizontalAlignment.Right;
            var panel = Ui.Stack(Ui.Text(title, 20, "Ink", true), Ui.Gap(17), new ScrollViewer { Content = body, MaxHeight = MaxHeight - 180 }, Ui.Gap(22), buttons);
            var shell = Ui.Card(panel, 25); shell.Margin = new Thickness(8); Content = shell;
            PreviewKeyDown += (s, e) => { if (e.Key == Key.Escape) { DialogResult = false; e.Handled = true; } };
        }
    }
}
