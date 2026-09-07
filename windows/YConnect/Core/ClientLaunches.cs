using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace YConnect.Core
{
    public sealed class ClientLaunchAttempt
    {
        public string Id { get; } = Guid.NewGuid().ToString("N");
        public string Client { get; internal set; }
        public string Model { get; internal set; }
        public string Directory { get; internal set; }
        public string Terminal { get; internal set; }
        public DateTime Created { get; } = DateTime.Now;
        public string State { get; internal set; } = "pending";
        public string Detail { get; internal set; } = "正在打开独立终端，可以继续启动其他会话。";
        internal CancellationTokenSource Watching { get; } = new CancellationTokenSource();
    }

    // Owned by the UI dispatcher; every call snapshots its plan and has its own
    // observation lifetime. Never retains a key, command line or plaintext config.
    public sealed class ClientLaunches : IDisposable
    {
        private readonly List<ClientLaunchAttempt> attempts = new List<ClientLaunchAttempt>();
        public IReadOnlyList<ClientLaunchAttempt> Attempts => attempts;
        public event Action Changed;
        public async Task<ClientLaunchAttempt> Start(ClientLaunchPlan plan, string terminal, Func<ClientLaunchPlan, string, CancellationToken, Task<string>> launch = null)
        {
            var attempt = new ClientLaunchAttempt { Client = plan.Session.Client, Model = plan.Session.Model, Directory = plan.Session.WorkingDirectory, Terminal = terminal };
            attempts.Insert(0, attempt);
            foreach (var old in attempts.Skip(12).Where(a => a.State != "pending").ToArray()) attempts.Remove(old);
            Changed?.Invoke();
            try
            {
                attempt.Detail = await (launch == null ? ClientLauncher.Start(plan, terminal, cancellation: attempt.Watching.Token) : launch(plan, terminal, attempt.Watching.Token));
                attempt.State = "ready";
            }
            catch (OperationCanceledException) { attempt.State = "unconfirmed"; attempt.Detail = "已停止等待；不会关闭终端，也不会影响其他会话。"; }
            catch (Exception error) { attempt.State = "failed"; attempt.Detail = error.Message; }
            finally { attempt.Watching.Dispose(); Changed?.Invoke(); }
            return attempt;
        }
        public void StopWaiting(string id) { var attempt = attempts.FirstOrDefault(a => a.Id == id); if (attempt?.State == "pending") attempt.Watching.Cancel(); }
        public void Dispose() { foreach (var attempt in attempts.Where(a => a.State == "pending")) attempt.Watching.Cancel(); }
    }
}
