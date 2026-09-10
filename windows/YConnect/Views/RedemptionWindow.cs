using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using YConnect.Core;

namespace YConnect.Views
{
    public sealed class RedemptionWindow : Window
    {
        private readonly YConnectStore store;
        private readonly Func<bool> isCurrentAccount;
        private readonly TextBox code = Ui.Id(new TextBox { MaxLength = 80 }, "overview-redeem-code");
        private readonly TextBlock feedback = Ui.Id(Ui.Text("", 12, "Muted"), "redemption-feedback");
        private readonly Button submit, close;
        private bool submitting;

        public RedemptionWindow(Window owner, YConnectStore store)
        {
            this.store = store; isCurrentAccount = store.CaptureAccountSession();
            Owner = owner; Title = "兑换码"; Width = 460; SizeToContent = SizeToContent.Height;
            WindowStartupLocation = WindowStartupLocation.CenterOwner; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false;
            SetResourceReference(BackgroundProperty, "Page");
            close = Ui.Button("关闭", "dialog-cancel", Close);
            submit = Ui.AsyncButton("兑换", "dialog-confirm", Submit, "Primary");
            submit.Margin = new Thickness(10, 0, 0, 0);
            var actions = Ui.Row(close, submit); actions.HorizontalAlignment = HorizontalAlignment.Right;
            Content = Ui.Card(Ui.Stack(Ui.Text("兑换码", 20, "Ink", true), Ui.Gap(12),
                Ui.Text("兑换至账户：" + store.DisplayName, 12, "Muted"), Ui.Gap(12),
                Ui.Text("输入 12–64 位字母、数字或连字符", 11, "Muted"), Ui.Gap(8), code,
                Ui.Gap(12), feedback, Ui.Gap(16), actions), 24);
            code.TextChanged += (s, e) => UpdateActions();
            ContentRendered += (s, e) => code.Focus();
            Closing += (s, e) => e.Cancel = submitting;
            PreviewKeyDown += async (s, e) => {
                if (e.Key == Key.Escape && !submitting) { Close(); e.Handled = true; }
                else if (e.Key == Key.Enter) { e.Handled = true; await Submit(); }
            };
            UpdateActions();
        }

        private void UpdateActions()
        {
            var valid = false;
            try { YConnectStore.NormalizeRedemptionCode(code.Text); valid = true; } catch (InvalidOperationException) { }
            submit.IsEnabled = valid && !submitting && !store.Busy && isCurrentAccount();
            close.IsEnabled = !submitting; code.IsEnabled = !submitting;
        }

        private async Task Submit()
        {
            if (!isCurrentAccount()) { feedback.Text = "账户已变更，请关闭后重新打开兑换码窗口"; UpdateActions(); return; }
            UpdateActions();
            if (!submit.IsEnabled) return;
            submitting = true; feedback.Text = "正在兑换…"; UpdateActions();
            try
            {
                var applied = false;
                var completed = await store.Run(async () => { applied = await store.Redeem(code.Text); });
                feedback.Text = store.Error ?? store.Message ?? "账户状态已变更，请关闭后重试";
                if (completed && applied) code.Clear();
            }
            finally { submitting = false; UpdateActions(); }
        }
    }
}
