function [posterior,out] = clock_tc_components_vba(file,showfig,model,basedir)
%% fits TC model to Clock Task subject data using VBA toolbox
% example call:
% [posterior,out]=clock_sceptic_vba(10638,'fixed',4,1,1,1)
% id:           5-digit subject id in Michael Hallquist's BPD study
% only works with 'fixed' (fixed learning rate SCEPTIC) so far
% n_basis:      8 works well, 4 also OK
% multinomial:  if 1 fits p_chosen from the softmax; continuous RT (multinomial=0) works less well
% multisession: treats runs/conditions as separate, helps fit (do not allow X0 to vary though)

%close all

n_t = 400; %400 trials
n_runs = 8;
trialsToFit = 1:n_t;

if nargin < 2, showfig = 1; end
if showfig==1
    options.DisplayWin=1;
else
    options.DisplayWin=0;
end

if nargin < 3, model = 'K_Lambda_Nu_AlphaG_AlphaN_Rho_Epsilon'; end
if nargin < 4, basedir='/Users/michael/Data_Analysis/temporal_instrumental_agent/clock_task/subjects'; end


%% fit as multiple runs
multisession = 1;
% fix parameters across runs
fixed_params_across_runs = 1;

%% u is 2 x ntrials where first row is rt and second row is reward
data = readtable(sprintf('%s/%s', basedir, file),'Delimiter',',','ReadVariableNames',true);
rts = data{trialsToFit, 'rt'};
rewards = data{trialsToFit, 'score'};
runsplit = repmat(n_t/n_runs,1,n_runs); %50 50 50 etc.
%% split into conditions/runs
if multisession %improves fits moderately
    options.multisession.split = runsplit
    %% fix parameters
    if fixed_params_across_runs
        options.multisession.fixed.theta = 'all';
        options.multisession.fixed.phi = 'all';
        % allow unique initial values for each run?
        options.multisession.fixed.X0 = [1 3 4 5 6 7 8 9 10]; %don't fix V (element 2) across runs (only for full model at the moment)
    end
end

priors.a_alpha = Inf;   %infinite precision prior on state noise precision (deterministic system)
priors.b_alpha = 0;
priors.a_sigma = 1;     % Jeffrey's prior (on measurement noise precision)
priors.b_sigma = 1;     % Jeffrey's prior

rtrescale = 1000; %put the RT-related hidden states on a similar scale as the others (i.e., divide by 1000)

%notes about full phi specification
%priors.muPhi = [0, ... %K (intercept) is ~N(0, 1) transformed into ~unif(0,4000). prior mu of 0 corresponds to middle of distribution = 2000
%    0, ... %lambda (autocorr) is ~N(0, 15) with exponential transform. So prior mu of 0 means lambda = 0.5
%    0, ... %nu (go for gold) is ~N(0, 15) with exponential transform and rescaled to max = 10. Prior of 0 means nu = 5
%    0, ... %rho (mean fast/slow) is ~N(0, 1), transformed into ~gamma(2,2)*400, so a value of 0 corresponds to rho ~ 1300
%    0, ... %epsilon (sd fast-slow explore) is ~N(0, 1), transformed into ~unif(0, 10000), so a value of 0 is an epsilon of 5000
%];

%priors.SigmaPhi = diag([1, 15, 15, 1, 1]); %initial variance of the phi parameters

priorNu = -4.5; %transforms to .11 with sigmoid and max of 10
%priorNu = -3;
priorLambda = -1; %transforms to .27
%priorLambda = -0.5;
multinomial = 0; %Gaussian prediction by default

%in full Frank TC, n_phi is 5 and n_theta is 2
%number of hidden states (n) is 10
if strcmpi(model, 'K')
    n_states = 0; %no hidden states
    n_theta = 0; %no evolution parameters
    n_phi = 1;
    priors.muTheta = []; %rmfield(priors, {'muTheta', 'SigmaTheta'}); %just to be safe
    priors.SigmaTheta = [];
    
    priors.muPhi = 0;
    priors.SigmaPhi = 1; %std normal K (transform to uniform)
elseif strcmpi(model, 'K_Lambda')
    n_states = 0;
    n_theta = 0;
    n_phi = 2; %K and Lambda
    priors.muTheta = []; %rmfield(priors, {'muTheta', 'SigmaTheta'}); %just to be safe
    priors.SigmaTheta = [];
    
    priors.muPhi = [0, priorLambda]; %K, Lambda
    priors.SigmaPhi = diag([1, 15]);
elseif strcmpi(model, 'K_Lambda_Nu')
    n_states=2;
    n_theta = 0;
    n_phi = 3; %K, Lambda, Nu
    priors.muTheta = []; %rmfield(priors, {'muTheta', 'SigmaTheta'}); %just to be safe
    priors.SigmaTheta = [];
    
    priors.muPhi = [0, priorLambda, priorNu]; %K, Lambda, Nu
    priors.SigmaPhi = diag([1, 15, 15]);
    
    priors.muX0 = [mean(rts)/rtrescale, ... %initial value of best RT
        0]; %V (value)
    
elseif strcmpi(model, 'K_Lambda_Nu_AlphaG')
    n_states = 3;
    n_theta = 1; %alphaG
    n_phi = 3; %K, Lambda, Nu
    
    %theta is alphaG (1)
    priors.muTheta = 0; %learning rate prior of 2.5: 5/(1+exp(0))
    priors.SigmaTheta = 15; %15 (broad) variance identity matrix -- leads to sd of 3.87, and 1/(1+exp(7.75)) approaches zero

    priors.muPhi = [0, priorLambda, priorNu]; %K, Lambda, Nu
    priors.SigmaPhi = diag([1, 15, 15]);
    
    priors.muX0 = [mean(rts)/rtrescale, ... %initial value of best RT
        0, ... %V (value)
        0]; %Go
    
elseif strcmpi(model, 'K_Lambda_Nu_AlphaG_AlphaN')
    n_states = 4;
    n_theta = 2; %alphaG and alphaN
    n_phi = 3; %K, Lambda, Nu 
    
    %theta is alphaG (1), alphaN (2)
    priors.muTheta = [0, 0]; %learning rate prior of 2.5: 5/(1+exp(0))
    priors.SigmaTheta = 15*eye(n_theta); %15 (broad) variance identity matrix -- leads to sd of 3.87, and 1/(1+exp(7.75)) approaches zero

    priors.muPhi = [0, priorLambda, priorNu]; %K, Lambda, Nu
    priors.SigmaPhi = diag([1, 15, 15]);
    
    priors.muX0 = [mean(rts)/rtrescale, ... %initial value of best RT
        0, ... %V (value)
        0, ... %Go
        0]; %NoGo
    
elseif strcmpi(model, 'K_Lambda_Nu_AlphaG_AlphaN_Rho')
    n_states = 10;
    n_theta = 2; %alphaG and alphaN
    n_phi = 4; %K, Lambda, Nu, Rho
    
    %theta is alphaG (1), alphaN (2)
    priors.muTheta = [0, 0]; %learning rate prior of 2.5: 5/(1+exp(0))
    priors.SigmaTheta = 15*eye(n_theta); %15 (broad) variance identity matrix -- leads to sd of 3.87, and 1/(1+exp(7.75)) approaches zero

    priors.muPhi = [0, priorLambda, priorNu, 0]; %K, Lambda, Nu, Rho
    priors.SigmaPhi = diag([1, 15, 15, 1]);
    
    priors.muX0 = [mean(rts)/rtrescale, ... %initial value of best RT
        0, ... %V (value)
        0, ... %Go
        0, ... %NoGo
        1.01, ... %a_fast (initial beta distribution hyperparameters)
        1.01, ... %b_fast
        1.01, ... %a_slow
        1.01, ... %b_slow
        mean(rts)/rtrescale, ... %initial RTlocavg
        0]; %sign of exploration influence

elseif strcmpi(model, 'K_Lambda_Nu_AlphaG_AlphaN_Rho_Epsilon')
    n_states = 10;
    n_theta = 2; %alphaG and alphaN
    n_phi = 5; %K, Lambda, Nu, Rho, Epsilon
    
    %theta is alphaG (1), alphaN (2)
    priors.muTheta = [0, 0]; %learning rate prior of 2.5: 5/(1+exp(0))
    priors.SigmaTheta = 15*eye(n_theta); %15 (broad) variance identity matrix -- leads to sd of 3.87, and 1/(1+exp(7.75)) approaches zero

    priors.muPhi = [0, priorLambda, priorNu, 0, 0]; %K, Lambda, Nu, Rho, Epsilon
    priors.SigmaPhi = diag([1, 15, 15, 1, 1]);
    
    priors.muX0 = [mean(rts)/rtrescale, ... %initial value of best RT
        0, ... %V (value)
        0, ... %Go
        0, ... %NoGo
        1.01, ... %a_fast (initial beta distribution hyperparameters)
        1.01, ... %b_fast
        1.01, ... %a_slow
        1.01, ... %b_slow
        mean(rts)/rtrescale, ... %initial RTlocavg
        0]; %sign of exploration influence
elseif strcmpi(model, 'K_Sticky_AlphaG_AlphaN_Rho_Epsilon')
    n_states = 11;
    n_theta = 3; %alphaG, alphaN, and decay
    n_phi = 4; %K, Lambda, Rho, Epsilon
    
    priors.muTheta = [0, 0, 0]; %learning rate prior of 2.5: 5/(1+exp(0))
    priors.SigmaTheta = 15*eye(n_theta); %15 (broad) variance identity matrix -- leads to sd of 3.87, and 1/(1+exp(7.75)) approaches zero. all three pars are 0..1 inverse logit

    priors.muPhi = [0, priorLambda, 0, 0]; %K, Lambda, Rho, Epsilon
    priors.SigmaPhi = diag([1, 15, 1, 1]); %1 is for fastnormcdf pars; 15 is for 0..1 inverse logit
    
    priors.muX0 = [mean(rts)/rtrescale, ... %initial value of best RT
        0, ... %V (value)
        0, ... %Go
        0, ... %NoGo
        1.01, ... %a_fast (initial beta distribution hyperparameters)
        1.01, ... %b_fast
        1.01, ... %a_slow
        1.01, ... %b_slow
        mean(rts)/rtrescale, ... %initial RTlocavg
        0, ... %sign of exploration influence
	0 ]; %sticky scalar
elseif strcmpi(model, 'K_Lambda_Nu_AlphaG_AlphaN_Rho_Epsilon_Multinomial')
    n_states = 10;
    n_theta = 2; %alphaG and alphaN
    n_phi = 6; %K, Lambda, Nu, Rho, Epsilon, Spread
    %n_phi = 5; %K, Lambda, Nu, Rho, Epsilon
    
    %theta is alphaG (1), alphaN (2)
    priors.muTheta = [0, 0]; %learning rate prior of 2.5: 5/(1+exp(0))
    priors.SigmaTheta = 15*eye(n_theta); %15 (broad) variance identity matrix -- leads to sd of 3.87, and 1/(1+exp(7.75)) approaches zero

    priors.muPhi = [-4, priorLambda, priorNu, 0, 0, 5]; %K, Lambda, Nu, Rho, Epsilon, Spread
    priors.SigmaPhi = diag([1, 15, 15, 1, 1, 15]);
    %priors.muPhi = [0, priorLambda, priorNu, 2, 2]; %K, Lambda, Nu, Rho, Epsilon
    %priors.SigmaPhi = diag([1, 15, 15, 1, 1]);
    
    priors.muX0 = [mean(rts)/rtrescale, ... %initial value of best RT
        0, ... %V (value)
        0, ... %Go
        0, ... %NoGo
        1.01, ... %a_fast (initial beta distribution hyperparameters)
        1.01, ... %b_fast
        1.01, ... %a_slow
        1.01, ... %b_slow
        mean(rts)/rtrescale, ... %initial RTlocavg
        0]; %sign of exploration influence
    
    multinomial = 1;
end

dim = struct('n',n_states,'n_theta',n_theta,'n_phi',n_phi, 'n_t', n_t);
y = data{trialsToFit,'rt'}';

options.binomial = 0;
options.sources(1) = struct('out',1,'type',0); %treat source/y as Gaussian

%% skip first trial (don't fit t=1)
options.skipf = zeros(1,n_t);
options.skipf(1) = 1;

priors.SigmaX0 = zeros(dim.n); %0 variance in initial states

options.priors = priors;

%% set up models within evolution/observation Fx
options.inF.maxAlpha = 5; %maximum alpha for Go and NoGo updates
options.inF.priors = priors; %copy priors into inF for parameter transformation
options.inF.RTrescale = rtrescale; %scale bestRT hidden state into seconds (for similarity across hidden states)
options.inG.maxNu = 10; %maximum nu for go for gold (tends to be between 0 and 1, though)
options.inG.rhoMultiply = 400; %leads to a max rho around 10000
%options.inG.epsilonMultiply = 1600; %for gamma-based epsilons: leads to a max epsilon around 58000
options.inG.maxEpsilon = 10000; %for uniform epsilon: the max of the inverse Gaussian -> Uniform transformation
options.inG.expEpsilonMean = 1000; %for Gaussian -> exponential transformed version of Epsilon. Exponential mean of 1000 yields range 0..~10000
options.inG.epsilonMultiply = 1200; %for Gaussian epsilon allowing for negative epsilons
options.inG.priors = priors; %copy priors into inG for parameter transformation (e.g., Gaussian -> uniform)
options.inG.maxRT = 4000; %maximum possible RT (used for uniform distribution)
options.inG.meanRT = mean(rts);
options.inG.RTrescale = rtrescale; %scale bestRT hidden state into seconds (for similarity across hidden states)
%options.inG.multinomial = multinomial;
options.inF.tcvariant = model; %pass along model variant to functions
options.inG.tcvariant = model;


options.TolFun = 1e-8;
options.GnTolFun = 1e-8;
options.verbose=1;

%rtsbyrun = reshape(rts, n_t/n_runs, n_runs)'; %convert to 8 x 50
runsum = [0, cumsum(runsplit)];
rtslag = NaN(n_runs, n_t/n_runs);
for i = 1:(length(runsum)-1)
    rtslag(i, :) = rts([runsum(i)+1, (runsum(i)+1):(runsum(i+1)-1)]);
end
rtslag = reshape(rtslag', n_t, 1); %flatten into vector row-wise

if multinomial
    ntimesteps = 40; %number of time bins
    range_RT = 4000; %maximum observed RT
    options.inG.ntimesteps = ntimesteps;
    options.inG.range_RT = range_RT;
    
    rtrnd = round(rts*ntimesteps/range_RT)';
    rtrnd(rtrnd==0)=1;
    dim.p = ntimesteps; %dimension of choice vector
    %options.sources(1) = struct('out',1:ntimesteps,'type',2); 
    options.sources(1) = struct('out',1:ntimesteps,'type',2); 
    
    y = zeros(ntimesteps, length(trialsToFit));
    for i = 1:length(trialsToFit)
        y(rtrnd(i), i) = 1;
    end
    
    options.binomial = 1; %multinomial fitting
end

rewardsbyrun = reshape(rewards, n_t/n_runs, n_runs)'; %convert to 8 x 50
rew_max = NaN(n_runs, n_t/n_runs);
for i = 1:n_runs
    best_rew=0;
    for t = 1:size(rewardsbyrun, 2)
        if rewardsbyrun(i, t) > best_rew, best_rew = rewardsbyrun(i, t); end
        rew_max(i, t) = best_rew;
    end
end
rew_max = reshape(rew_max', n_t, 1); %flatten into vector row-wise

rew_std = NaN(n_runs, n_t/n_runs);
for i = 1:n_runs
    for t = 1:size(rewardsbyrun, 2)
        rew_std(i, t) = std(rewardsbyrun(i, 1:t));
    end
end
rew_std = reshape(rew_std', n_t, 1); %flatten into vector row-wise

%for now, all models receive all inputs... but some don't use them internally
u  = [rts'; rtslag'; rewards'; rew_max'; rew_std'];

%alex: let me know if you think the right-shift is needed here to get the t versus t-1 right
%u = [zeros(size(u,1),1) u(:,1:end-1)];

fprintf('Fitting model: %s\n', model);
tic;
[posterior,out] = VBA_NLStateSpaceModel(y,u,@clock_tc_components_evolution,@clock_tc_components_observation,dim,options);
elapsed=toc;
fprintf('Model converged in %.2f seconds\n', elapsed);

if strcmpi(model, 'K_Sticky_AlphaG_AlphaN_Rho_Epsilon')
    posterior.transformed.K = unifinv(fastnormcdf(posterior.muPhi(1)), 0, options.inG.maxRT);
    posterior.transformed.lambda = 1 / (1+exp(-posterior.muPhi(2))); %in the sticky modmel, this scales lambda*sticky(t)
    posterior.transformed.rho = options.inG.rhoMultiply * gaminv(fastnormcdf(posterior.muPhi(3)), 2, 2);
    posterior.transformed.epsilon = options.inG.epsilonMultiply * posterior.muPhi(4);
    posterior.transformed.alphaG = options.inF.maxAlpha / (1+exp(-posterior.muTheta(1)));
    posterior.transformed.alphaN = options.inF.maxAlpha / (1+exp(-posterior.muTheta(2)));
    posterior.transformed.decay = 1 / (1+exp(-posterior.muTheta(3)));
else
    if ~isempty(regexp(model, '^K_?', 'once')), posterior.transformed.K = unifinv(fastnormcdf(posterior.muPhi(1)), 0, options.inG.maxRT); end
    if ~isempty(regexp(model, '_Lambda', 'once')), posterior.transformed.lambda = 1 / (1+exp(-posterior.muPhi(2))); end
    if ~isempty(regexp(model, '_Nu', 'once')), posterior.transformed.nu = options.inG.maxNu / (1+exp(-posterior.muPhi(3))); end
    if ~isempty(regexp(model, '_AlphaG', 'once')), posterior.transformed.alphaG = options.inF.maxAlpha / (1+exp(-posterior.muTheta(1))); end
    if ~isempty(regexp(model, '_AlphaN', 'once')), posterior.transformed.alphaN = options.inF.maxAlpha / (1+exp(-posterior.muTheta(2))); end
    if ~isempty(regexp(model, '_Rho', 'once')), posterior.transformed.rho = options.inG.rhoMultiply * gaminv(fastnormcdf(posterior.muPhi(4)), 2, 2); end
    %if ~isempty(regexp(model, '_Epsilon', 'once')), posterior.transformed.epsilon = unifinv(fastnormcdf(posterior.muPhi(5)), 0, options.inG.maxEpsilon); end %uniform variant
    if ~isempty(regexp(model, '_Epsilon', 'once')), posterior.transformed.epsilon = expinv(fastnormcdf(posterior.muPhi(5)), options.inG.expEpsilonMean); end %exponential variant
    %if ~isempty(regexp(model, '_Epsilon', 'once')), posterior.transformed.epsilon = options.inG.epsilonMultiply * posterior.muPhi(5); end %+/- Gaussian variant
    %if ~isempty(regexp(model, '_Multinomial', 'once')), posterior.transformed.spread = posterior.muPhi(6); end
end

%% save output figure
%if (showfig==1)
%    h = figure(1);
%    %savefig(h,sprintf('results/%d_%s_vba',id, model));
%    %savefig(h,sprintf('%d_%s_multinomial%d_multisession%d_fixedParams%d',id,model,multinomial,multisession,fixed_params_across_runs))
%end
%save(sprintf('results/%d_tc_vba_fit', id), 'posterior', 'out');
