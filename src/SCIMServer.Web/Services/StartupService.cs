using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using System;
using System.Threading;
using System.Threading.Tasks;

namespace SCIMServer.Web.Services
{
    /// <summary>
    /// Hosted service that runs startup checks
    /// </summary>
    public class StartupService : IHostedService
    {
        private readonly ILogger<StartupService> _logger;
        private readonly IServiceProvider _serviceProvider;
        private readonly IHostApplicationLifetime _lifetime;

        /// <summary>
        /// Initializes a new instance of the StartupService class
        /// </summary>
        public StartupService(
            ILogger<StartupService> logger,
            IServiceProvider serviceProvider,
            IHostApplicationLifetime lifetime)
        {
            _logger = logger;
            _serviceProvider = serviceProvider;
            _lifetime = lifetime;
        }

        /// <summary>
        /// Starts the service
        /// </summary>
        public async Task StartAsync(CancellationToken cancellationToken)
        {
            _logger.LogInformation("SCIM Server starting...");

            try
            {
                // Check if setup is required
                using var scope = _serviceProvider.CreateScope();
                var setupService = scope.ServiceProvider.GetRequiredService<SetupService>();
                var url = scope.ServiceProvider.GetRequiredService<IConfiguration>()["Kestrel:Endpoints:Http:Url"] ?? "http://localhost:5000";
                var setupRequired = await setupService.IsSetupRequiredAsync();

                if (setupRequired)
                {
                    _logger.LogWarning("Initial setup required. Please navigate to /setup to configure SCIM Server.");
                    Console.WriteLine();
                    Console.WriteLine("========================================");
                    Console.WriteLine("  SCIM Server - Initial Setup Required");
                    Console.WriteLine("========================================");
                    Console.WriteLine();
                    Console.WriteLine("This appears to be the first time running SCIM Server.");
                    Console.WriteLine("Please open your web browser and navigate to:");
                    Console.WriteLine();
                    Console.WriteLine($"  {url}/setup");
                    Console.WriteLine();
                    Console.WriteLine("to complete the initial configuration.");
                    Console.WriteLine();
                }
                else
                {
                    _logger.LogInformation("SCIM Server is ready!");
                    Console.WriteLine();
                    Console.WriteLine("========================================");
                    Console.WriteLine("  SCIM Server Started Successfully");
                    Console.WriteLine("========================================");
                    Console.WriteLine();
                    Console.WriteLine($"Web UI: {url}");
                    Console.WriteLine($"API Base: {url}/scim/v2");
                    Console.WriteLine();
                }
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Error during startup checks, setup may be required");
                // Don't stop — let SetupMiddleware redirect to /setup
            }
        }

        /// <summary>
        /// Stops the service
        /// </summary>
        public Task StopAsync(CancellationToken cancellationToken)
        {
            _logger.LogInformation("SCIM Server stopped.");
            return Task.CompletedTask;
        }
    }
}