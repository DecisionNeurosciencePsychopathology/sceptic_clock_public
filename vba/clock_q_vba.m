function [posterior,out] = clock_q_vba(id,showfig, multinomial,multisession,fixed_params_across_runs,fit_propspread,n_steps,saveresults)
%Working draft of getting q learning to work with vba toolbox

%Set data directory
% if ~isempty(strfind(pwd,'vba'))
%     vbadir = pwd;
% else
%     command = 'find . -iname ''vba''';
%     try
%         [~,cmdout]=system(command);
%         cd(cmdout)
%         vbadir = pwd;
%     catch
%         fprintf('\nError: please go to the vba directory and run this command')
%     end
% end

if saveresults
    %vbadir = 'E:\data\clock_task\vba\qlearning_vba_results\individual_results';
    %vbadir= '/Users/dombax/Google Drive/skinner/SCEPTIC/subject_fitting/vba_results';
    results_dir = '/Volumes/bek/vba_results/';
    
end

if nargin < 2, showfig = 1; end

if showfig==1
    options.DisplayWin=1;
else
    options.DisplayWin=0;
end

%% fit as multiple runs
%multisession = 1;
% fix parameters across runs
%fixed_params_across_runs = 1;

%% u is 2 x ntrials where first row is rt and second row is reward
% os = computer;
%data = readtable(sprintf('/Users/dombax/temporal_instrumental_agent/clock_task/subjects/fMRIEmoClock_%d_tc_tcExport.csv', id),'Delimiter',',','ReadVariableNames',true);
data = readtable(sprintf('../subjects/fMRIEmoClock_%d_tc_tcExport.csv',id));
%id),'Delimiter',',','ReadVariableNames',true); %This broke for some reason...
% rts = data{trialsToFit, 'rt'};
% rewards = data{trialsToFit, 'score'};

%%
close all

graphics = showfig;
if ~graphics
    options.DisplayWin = 0;
    options.GnFigs = 0;
end
%% set up dim defaults
n_theta = 1;
n_phi = 1;
%range_RT = 40; %Smaller bin size
range_RT = n_steps; %Smaller bin size
n_t = size(data,1);
n_runs = n_t/50;
trialsToFit = 1:n_t;
options.inF.fit_propspread = fit_propspread;
model = 'q_step'; %Set the model name


%% set up models within evolution/observation Fx
%Note: we might need to add option.inF.model to make the kalman models
%easier to deal with...
options.inF.ntimesteps = n_steps;
options.inG.ntimesteps = n_steps;
options.inG.multinomial = multinomial;
options.inG.maxRT = range_RT;
%%
options.TolFun = 1e-6;
options.GnTolFun = 1e-6;
options.verbose=1;
%options.DisplayWin=1;
%%
options.inF.first_iteration = 1;
options.inF.random_actions = randi(2,n_steps,1);


%% split into conditions/runs
if multisession %improves fits moderately
    options.multisession.split = repmat(n_t/n_runs,1,n_runs); % two sessions of 120 datapoints each
    %% fix parameters
    if fixed_params_across_runs
        options.multisession.fixed.theta = 'all';
        options.multisession.fixed.phi = 'all';
        %
        % allow unique initial values for each run?
        options.multisession.fixed.X0 = 'all';
    end
    
end

%Determine which evolution funciton to use
h_name = @h_qlearning;
n_hidden_variables = 2;
n_hidden_states = n_hidden_variables*n_steps;

% set up Priors
priors.muX0 = zeros(n_hidden_states,1);
priors.SigmaX0 = zeros(n_hidden_states);

if multinomial
    rtrnd = round(data{trialsToFit(1:end),'rt'}*0.01*n_steps/range_RT)';
    rtrnd(rtrnd==0)=1;
    dim = struct('n',n_hidden_states,'n_theta',n_theta,'n_phi',n_phi,'p',n_steps);
    options.sources(1) = struct('out',1:n_steps,'type',2);
    
    %% compute multinomial response -- renamed 'y' here instead of 'rtbin'
    y = zeros(n_steps, length(trialsToFit));
    for i = 1:length(trialsToFit)
        y(rtrnd(i), i) = 1;
    end
    priors.a_alpha = Inf;   % infinite precision prior
    priors.b_alpha = 0;
    priors.a_sigma = 1;     % Jeffrey's prior
    priors.b_sigma = 1;     % Jeffrey's prior
    options.binomial = 1;
    priors.muPhi = zeros(dim.n_phi,1); % exp tranform
    priors.SigmaPhi = 1e1*eye(dim.n_phi);
    % Inputs
    %u = [(data{trialsToFit, 'rt'}*0.1*n_steps/range_RT)'; data{trialsToFit, 'score'}'];
    u = [rtrnd; data{trialsToFit, 'score'}'; (1:n_t)];
    u = [zeros(size(u,1),1) u(:,1:end-1)];
    % Observation function
    g_name = @g_qlearning_step_wise;
    
else
    n_phi = 2; % [autocorrelation lambda and response bias/meanRT K] instead of temperature
    dim = struct('n',n_hidden_states,'n_theta',n_theta,'n_phi',n_phi, 'n_t', n_t);
    rtrnd=round((data{trialsToFit, 'rt'}*0.01*n_steps/range_RT)');
    rtrnd(rtrnd==0)=1;
    y = (data{trialsToFit,'rt'}*0.01*n_steps/range_RT)';
    %y = (data{trialsToFit,'rt'}*0.01*n_steps/range_RT)';
    
    priors.a_alpha = Inf;
    priors.b_alpha = 0;
    priors.a_sigma = 1;     % Jeffrey's prior
    priors.b_sigma = 1;     % Jeffrey's prior
    priors.muPhi = [0, 0];
    priors.SigmaPhi = diag([1,1]);
    options.binomial = 0;
    options.sources(1) = struct('out',1,'type',0);
    prev_rt = [0 y(1:end-1)];
    % Inputs (rt, score, trial)
    %u = [(data{trialsToFit, 'rt'}*0.01*n_steps/range_RT)'; data{trialsToFit, 'score'}'; (1:n_t)];
    u = [rtrnd; data{trialsToFit, 'score'}'; (1:n_t)];
    % Observation function
    g_name = @g_qlearning_step_wise;
    
end


%% skip first trial
options.skipf = zeros(1,n_t);
options.skipf(1) = 1;

%% priors
priors.muTheta = zeros(dim.n_theta,1);
priors.SigmaTheta = 1e1*eye(dim.n_theta);
options.priors = priors;
options.inG.priors = priors; %copy priors into inG for parameter transformation (e.g., Gaussian -> uniform)

[posterior,out] = VBA_NLStateSpaceModel(y,u,h_name,g_name,dim,options);

%cd(vbadir);
%% save output figure
% h = figure(1);
% savefig(h,sprintf('results/%d_%s_multinomial%d_multisession%d_fixedParams%d',id,model,multinomial,multisession,fixed_params_across_runs))
if saveresults
    %% save output figure
    % h = figure(1);
    % savefig(h,sprintf('results/%d_%s_multinomial%d_multisession%d_fixedParams%d',id,model,multinomial,multisession,fixed_params_across_runs))
    %I believe the issue with not saving the entire out and posterior, were
    %that they were exceptionally large. 'out' was over 5 GB alone! So I
    %only grabbed the most important ones I hope...
    important_vars.out.F = out.F;
    important_vars.posterior.muPhi = posterior.muPhi;
    important_vars.posterior.SigmaPhi = posterior.SigmaPhi;
    important_vars.posterior.muTheta = posterior.muTheta;
    important_vars.posterior.SigmaTheta = posterior.SigmaTheta;
    %save(sprintf([results_dir 'q_test/SHIFTED_U_CORRECT%d_%s_multinomial%d_multisession%d_fixedParams%d_fixed_prop_spread'], id, model, multinomial,multisession,fixed_params_across_runs), 'posterior', 'out');
    save(sprintf([results_dir 'q_test/SHIFTED_U_CORRECT%d_%s_multinomial%d_multisession%d_fixedParams%d_fixed_prop_spread'], id, model, multinomial,multisession,fixed_params_across_runs), 'important_vars');
    
end





