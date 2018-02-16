﻿using System;
using System.Data;
using NewRelic.Agent.Extensions.Providers.Wrapper;
using NewRelic.Parsing;
using NewRelic.Parsing.ConnectionString;
using NewRelic.Providers.Wrapper.WrapperUtilities;
using NewRelic.Agent.Extensions.Parsing;

namespace NewRelic.Providers.Wrapper.SqlAsync
{
	public class SqlCommandWrapper : IWrapper
	{
		public const string WrapperName = "SqlCommandWrapperAsync";

		public bool IsTransactionRequired => true;

		public CanWrapResponse CanWrap(InstrumentedMethodInfo methodInfo)
		{
			var method = methodInfo.Method;

			var isRequestedByName = WrapperName == methodInfo.RequestedWrapperName;

			var canWrap = isRequestedByName || method.MatchesAny(
				assemblyNames: new[]
				{
					"System.Data",
					"System.Data.SqlClient"
				},
				typeNames: new[]
				{
					"System.Data.SqlClient.SqlCommand"
				},
				methodNames: new[]
				{
					"ExecuteReaderAsync",
					"ExecuteNonQueryAsync",
					"ExecuteScalarAsync",
					"ExecuteXmlReaderAsync"
				});

			if (canWrap)
			{
				return WrapperUtils.LegacyAspPipelineIsPresent()
					? new CanWrapResponse(false, WrapperUtils.LegacyAspPipelineNotSupportedMessage("System.Data", "System.Data.SqlClient.SqlCommand", method.MethodName))
					: new CanWrapResponse(true);

			}

			return new CanWrapResponse(false);
		}

		public AfterWrappedMethodDelegate BeforeWrappedMethod(InstrumentedMethodCall instrumentedMethodCall, IAgentWrapperApi agentWrapperApi, ITransaction transaction)
		{
			if (instrumentedMethodCall.IsAsync)
			{
				transaction.AttachToAsync();
			}

			var sqlCommand = (IDbCommand)instrumentedMethodCall.MethodCall.InvocationTarget;
			if (sqlCommand == null)
				return Delegates.NoOp;

			var sql = sqlCommand.CommandText ?? String.Empty;

			// NOTE: this wrapper currently only supports SqlCommand. If support for other commands is added then the vendor will need to be determined dynamically.
			var vendor = SqlWrapperHelper.GetVendorName(sqlCommand);
			object GetConnectionInfo() => ConnectionInfoParser.FromConnectionString(vendor, sqlCommand.Connection.ConnectionString);
			var connectionInfo = (ConnectionInfo) transaction.GetOrSetValueFromCache(sqlCommand.Connection.ConnectionString, GetConnectionInfo);

			// TODO - Tracer had a supportability metric here to report timing duration of the parser.
			var parsedStatement = transaction.GetParsedDatabaseStatement(vendor, sqlCommand.CommandType, sql);
			var segment = transaction.StartDatastoreSegment(instrumentedMethodCall.MethodCall, parsedStatement, connectionInfo, sql);

			if (vendor == DatastoreVendor.MSSQL)
			{
				agentWrapperApi.EnableExplainPlans(segment, () => SqlServerExplainPlanActions.AllocateResources(sqlCommand), SqlServerExplainPlanActions.GenerateExplainPlan);
			}
			else if (vendor == DatastoreVendor.MySQL)
			{
				agentWrapperApi.EnableExplainPlans(segment, () => MySqlExplainPlanActions.AllocateResources(sqlCommand), MySqlExplainPlanActions.GenerateExplainPlan);
			}

			return WrapperUtils.GetAsyncDelegateFor(agentWrapperApi, segment);
		}
	}
}