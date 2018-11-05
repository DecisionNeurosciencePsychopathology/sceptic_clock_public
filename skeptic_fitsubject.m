%Kalman filter extension of temporal basis operator: each basis function tracks the mean value and uncertainty (sd) as a
%Gaussian.
%Authors: Michael Hallquist, Alex Dombrovski, & Jonathan Wilson
%Date last modified: 4/21/2015
%Matlab Version: R2012a
%fit subject behavior using skeptic (Strategic Kalman filter Exploration/Exploitation of Temporal Instrumental
%Contingencies)

%% TODO
% 1) downweight costs at beginning of the trial prior to when people are likely able to respond (< 250ms)
%       - This may just mean setting a minimum acceptable model-predicted RT (censor)


%%
function [cost,ret,mov] = skeptic_fitsubject(params, rt_obs, rew_obs, rngseeds, nbasis, ntimesteps, trial_plots, cond, minrt, maxrt)
%params is the vector of parameters used to fit
%   params(1): epsilon -- tradeoff point for exploration/exploitation
%   params(2): prop_spread -- width of temporal generalization Gaussian as a proportion of the time interval (0..1)
%   params(3): k -- proportion of strategic versus stochastic exploration
%   params(4): s_grw -- width of Gaussian random walk (GRW) for stochastic exploration
%cond is the character string of the reward contingency
%ntrials is the number of trials to run
%nbasis is the number of radial basis functions used to estimate value and uncertainty
%ntimesteps is the number of time bins used for obtaining estimates of time functions for plotting etc.

ret=[];
ntrials=length(rew_obs);

%% free parameters: exploration tradeoff (epsilon), temporal decay (sd of Gaussian temporal spread)
epsilon = params(1);
if epsilon<0 || epsilon>1
    error('Epsilon outside of bounds');
end

%for now, setup the hack (just for prototype) that epsilon is the proportion reduction in variance at which
%exploration versus exploitation become equally probable in the sigmoid. Need to have a nicer choice rule that
%integrates time-varying information about value and uncertainty.

%note: Kalman filter does not have a free learning rate parameter.
if length(params) < 2
    disp('defaulting to prop_spread=.02');
    prop_spread = .02; %sigma of temporal spread function as a proportion of the finite interval (0..0.5)
else
    prop_spread = params(2);
end

if length(params) == 3    
    spotlight = params(3); %proportion of the total interval over which subject evaluates U (bouncing around value max)
    disp(['spotlight enabled with prop: ', num2str(spotlight)]);
else
    disp('spotlight disabled');
    spotlight = 2; %max over full interval (since spotlight is proportion/2
end

%if (length(params)) < 3
    disp('defaulting to no Gaussian random walk: k=0, s_grw=0');
    k=0;
    s_grw=0;
%else
%    k=params(3);
%    s_grw=params(4);    
%    %for now, don't link sigma for GRW to uncertainty (but could so that GRW decays with uncertainty)
%end

if nargin < 4
    rngseeds=[98 83 66 10];
end

if nargin < 5, nbasis = 24; end
if nargin < 6, ntimesteps=400; end
if nargin < 7, trial_plots = 1; end
if nargin < 9, minrt=25; end %minimum 250ms RT
if nargin <10, maxrt=400; end


%treats time steps and max time as synonymous
fprintf('Downsampling rt_obs by a factor of 10 to to 0..%d\n', ntimesteps);
rt_obs = round(rt_obs/10);

%subtract off minimum rt so that subject's min RT or 25 (250ms) is now treated as 0
%also need to shift the basis by the corresponding amount so that
%ntimesteps = 375 if min RT = 250ms; also truncate basis on the right (late)
%end to reflect subject's max RT
rt_obs = rt_obs - minrt+1;
%occasional subjects are very fast, so
rt_obs(rt_obs<1) = 1;
ntimesteps = ntimesteps - minrt+1 - (400-maxrt);

%states for random generators are shared across functions to allow for repeatable draws
global rew_rng_state explore_rng_state;

%initialize states for two repeatable random number generators using different seeds
rew_rng_seed=rngseeds(1);
explore_rng_seed=rngseeds(2);
grw_step_rng_seed=rngseeds(3);
exptype_rng_seed=rngseeds(4);

rng(rew_rng_seed);
rew_rng_state=rng;
rng(explore_rng_seed);
explore_rng_state=rng;
rng(grw_step_rng_seed);
grw_step_rng_state=rng;
rng(exptype_rng_seed);
exptype_rng_seed=rng;

%initialize movie storage
mov=repmat(struct('cdata', [], 'colormap', []), ntrials,1);

%define radial basis
[c, tvec, sig_spread, refspread] = setup_rbf(ntimesteps, nbasis, prop_spread);

%rescale s_grw wrt the interval (not as a proportion)
s_grw=s_grw*range(tvec); %determine SD of spread function

%add Gaussian noise with sigma = 1% of the range of the time interval to rt_explore
prop_expnoise=.01;
sig_expnoise=prop_expnoise*range(tvec);

%setup matrices for tracking learning
% i = trial
% j = basis function
% t = time step within trial, in centiseconds (1-500, representing 0-5 seconds)
delta_ij =      zeros(ntrials, nbasis);     % prediction error assigned to each microstimulus
e_ij =          zeros(ntrials, nbasis);     % eligibility traces for each microstimulus in relation to RT (US)
v_jt =          zeros(nbasis, ntimesteps);  % value by microstimulus (rows for every microstimulus and columns for time points within trial)
v_it =          zeros(ntrials, ntimesteps); % history of value function by trial
ev_obs_i =      nan(1, ntrials);            % expected value of observed choices for each trial (used for comparing subject and model)
ev_pred_i =     nan(1, ntrials);            % expected value of predicted choices
u_jt =          zeros(nbasis, ntimesteps);  % uncertainty of each basis for each timestep
u_it =          zeros(ntrials,ntimesteps);  % history of uncertainty by trial at each timestep
d_i =           nan(1, ntrials);            % euclidean distance (in U and Q space) between obs and pred RTs
precision_i =   nan(1, ntrials);            % model-predicted certainty about choice type (explore/exploit)... Used for downweighting costs for uncertain choices

%kalman setup
mu_ij =         nan(ntrials, nbasis);       %means of Gaussians for Kalman
k_ij =          zeros(ntrials, nbasis);     %Kalman gain (learning rate)
sigma_ij =      zeros(ntrials, nbasis);     %Standard deviations of Gaussians (uncertainty)

mu_ij(1,:) =    0; %expected reward on first trial is initialized to 0 for all Gaussians.

rt_pred_i =          nan(1, ntrials);            % predicted reaction times
rts_pred_explore =   nan(1, ntrials);            % predicted exploratory reaction times
rts_pred_exploit =   nan(1, ntrials);            % predicted exploitative reaction times
exploit_trials =     [];                         %vector of trials where model predicts exploitation
explore_trials =     [];                         %vector of trials where model predicts exploration
p_explore_i =        nan(1, ntrials);            %model-predicted probability of exploration

rt_pred_i(1) = rt_obs(1); %first choice is exogenous to model
rts_pred_explore(1) = rt_obs(1); %first choice is exogenous to model
rts_pred_exploit(1) = rt_obs(1); %first choice is exogenous to model

%distance between predicted and observed set to 0 for first trial
d_i(1) = 0;

%noise in the reward signal: sigma_rew. In the Frank model, the squared SD of the Reward vector represents the noise in
%the reward signal, which is part of the Kalman gain. This provides a non-arbitrary initialization for sigma_rew, such
%that the variability in returns is known up front... This is implausible from an R-L perspective, but not a bad idea
%for getting a reasonable estimate of variability in returns. It would be interesting (plausible) to give a unique
%estimate to each basis based on its temporal receptive field, but hard to decide this up front. But it does seem like
%this could give local sensitivity to volatility (e.g., low- versus high-probability windows in time). For now, I'll
%just use the variance of the returns (ala Frank). But for the generative agent, this is not known up front -- so sample
%from the chosen contingency for each timestep as a guess.

%sigma_noise = repmat(std(arrayfun(@(x) RewFunction(x*10, cond, 0), tvec))^2, 1, nbasis);

%use observed volatility of choices (gives model some unfair insight into future... but need a basis for
%expected volatility/process noise)
sigma_noise = repmat(var(rew_obs), 1, nbasis);

u_threshold = (1-epsilon) * sigma_noise(1); %proportion reduction in variance from initial

%As in Frank, initialize estimate of std of each Gaussian to the noise of returns on a sample of the whole contingency.
%This leads to an effective learning rate of 0.5 since k = sigma_ij / sigma_ij + sigma_noise
sigma_ij(1,:) = sigma_noise; 

%fprintf('updating value by alpha: %.4f\n', alpha);
%fprintf('updating value by epsilon: %.4f with rngseeds: %s \n', epsilon, num2str(rngseeds));
%fprintf('running agent with sigs: %.3f, epsilon: %.3f and rngseeds: %s \n', sig_spread, epsilon, num2str(rngseeds));

%10/16/2014 NB: Even though some matrices such as v_it have columns for discrete timesteps, the
%agent now learns entirely on a continuous time basis by maximizing the value and uncertainty curves over the
%radial basis set and estimating total uncertainty as the definite integral of the uncertainty function over the
%time window of the trial.

%objective expected value for this function
%ev=[];
%for val = 1:length(tvec)
%    [~,ev(val)] = RewFunction(tvec(val).*10, cond);
%end

%figure(6); plot(tvec, ev);
%title('Expected value of contingency');

%Set up to run multiple runs for multiple ntrials
for i = 1:ntrials
    
    % get symmetric eligibility traces for each basis function (temporal generalization)
    % generate a truncated Gaussian basis function centered at the RT and with sigma equal to the free parameter.
    
    %compute gaussian spread function with mu = rt_obs(i) and sigma based on free param prop_spread
    elig = gaussmf(tvec, [sig_spread, rt_obs(i)]);
    
    %compute sum of area under the curve of the gaussian function
    auc=sum(elig);
    
    %divide gaussian update function by its sum so that AUC=1.0, then rescale to have AUC of a non-truncated basis
    %this ensures that eligibility is 0-1.0 for non-truncated update function, and can exceed 1.0 at the edge.
    %note: this leads to a truncated gaussian update function defined on the interval of interest because AUC
    %will be 1.0 even for a partial Gaussian where part of the distribution falls outside of the interval.
    elig=elig/auc*refspread;
    
    %truncated gaussian eligibility
    %figure(7); plot(tvec, elig);
    
    %compute the product of the Gaussian spread function with the truncated Gaussian basis.
    e_ij(i,:) = sum(repmat(elig,nbasis,1).*gaussmat_trunc, 2);

    %Changing Kalman variance a posteriori should also use the elig*gain approach: [1 - k(ij)*elig(ij)]*sigma(ij)
    %this would only allow a 1.0 update*kalman gain for basis functions solidly in the window and a decay in diminishing
    %variance as the basis deviates from the timing of the obtained reward.
       
    %1) compute the Kalman gains for the current trial
    k_ij(i,:) = sigma_ij(i,:)./(sigma_ij(i,:) + sigma_noise);

    %2) update posterior variances on the basis of Kalman gains
    sigma_ij(i+1,:) = (1 - e_ij(i,:).*k_ij(i,:)).*sigma_ij(i,:);
    
    %3) update reward expectation
    delta_ij(i,:) = e_ij(i,:).*(rew_obs(i) - mu_ij(i,:));
    mu_ij(i+1,:) = mu_ij(i,:) + k_ij(i,:).*delta_ij(i,:);
    
    v_jt=mu_ij(i+1,:)'*ones(1,ntimesteps) .* gaussmat; %use vector outer product to replicate weight vector
    
    %subjective value by timestep as a sum of all basis functions
    v_func = sum(v_jt);
    
    %uncertainty is now a function of Kalman uncertainties.
    u_jt=sigma_ij(i+1,:)'*ones(1,ntimesteps) .* gaussmat;
    u_func = sum(u_jt);

    v_it(i+1,:) = v_func;
    u_it(i+1,:) = u_func;
    
    %% CHOICE RULE
    % find the RT corresponding to exploitative choice (choose randomly if value unknown)
    % NB: we added just a little bit of noise
    if sum(v_func) == 0        
        rt_exploit = rt_obs(1); %feed RT exploit the first observed RT
    else
        %DANGER: fminbnd is giving local minimum solution that clearly
        %misses the max value. Could switch to something more comprehensive
        %like rmsearch, but for now revert to discrete approximation
        %rt_exploit = fminbnd(@(x) -rbfeval(x, mu_ij(i+1,:), c, ones(1,nbasis).*sig), 0, 500);
        %figure(2);
        %vfunc = rbfeval(0:500, mu_ij(i+1,:), c, ones(1,nbasis).*sig);
        %plot(0:500, vfunc);
        rt_exploit = find(v_func==max(v_func));
        %rt_exploit = max(round(find(v_func==max(v_func(20:500)))))-5+round(rand(1).*10);
        if rt_exploit > max(tvec)
            rt_exploit = max(tvec);
        elseif rt_exploit < minrt
            rt_exploit = minrt; %do not allow choice below earliest possible response
        end
        if rt_exploit > ntimesteps
            rt_exploit = ntimesteps;
        end
    end
        
    % find the RT corresponding to uncertainty-driven exploration (try random exploration if uncertainty is uniform)
    
    % u -- total amount of uncertainty on this trial (starts at 0 and decreases)
    % u = mean(u_func);
    
    %use integration to get area under curve of uncertainty
    %otherwise, our estimate of u is discretized, affecting cost function
    
    total_u = integral(@(x)rbfeval(x, sigma_ij(i+1,:), c, ones(1,nbasis).*sig), min(tvec), max(tvec));
    u = total_u/max(tvec); %make scaling similar to original sum? (come back)...
    
    if u == 0
        rt_explore = rt_obs(1); %%FEED RTOBS(1) on the first trial so that the fit is not penalized by misfit on first choice
    else
        %rt_explore = fminbnd(@(x) -rbfeval(x, sigma_ij(i+1,:), c, ones(1,nbasis).*sig), 0, 500);
        %leave out any gaussian noise from RT explore because we can't expect subject's data to fit with
        %random additive noise here.
        
        %u_func_spotlight = u_func;
        spotlight_min = max(minrt, round(rt_exploit - spotlight*ntimesteps/2));
        spotlight_max = min(ntimesteps, round(rt_exploit + spotlight*ntimesteps/2));
        look = zeros(1,ntimesteps);
        look(spotlight_min:spotlight_max) = 1;
        u_func_spotlight = u_func.*look;
                
        %rt_explore = find(u_func==max(u_func), 1); + round(sig_expnoise*randn(1,1)); %return position of first max and add gaussian noise
        rt_explore = find(u_func_spotlight==max(u_func_spotlight), 1); + round(sig_expnoise*randn(1,1)); %return position of first max and add gaussian noise       
        
        if rt_explore < minrt
            rt_explore = minrt;  %do not allow choice below earliest possible response
        end
        if rt_explore > ntimesteps
            rt_explore = ntimesteps;
        end
    end

    %fprintf('trial: %d rt_exploit: %.2f rt_explore: %.2f\n', i, rt_exploit, rt_explore);
    
    discrim = 0.1;
    p_explore_i(i) = 1/(1+exp(-discrim.*(u - u_threshold))); %Rasch model with epsilon as difficulty (location) parameter
        
    %soft classification (explore in proportion to uncertainty)
    rng(explore_rng_state); %draw from explore/exploit rng
    choice_rand=rand;
    explore_rng_state=rng; %save state after random draw above
    
    %% AD: the GRW exploration leads agent to repeat subject's RT
    %   solution: skip it for now 
    
    %determine whether to strategic explore versus GRW
    rng(exptype_rng_seed);
%     explore_type_rand=rand;
    exptype_rng_seed=rng;
    
    
    
    %determine step size for GRW
    rng(grw_step_rng_state); %draw from GRW rng
    grw_step=round(s_grw*randn(1,1));
    grw_step_rng_state=rng; %save state after draw 

    %% AD: NB grw exploration is commented out here to avoid circularity with subject's choices
    
    %rng('shuffle');
    if i < ntrials
        if choice_rand < p_explore_i(i)
%             if (explore_type_rand > k)
                %strategic
                exptxt='strategic explore';
                rt_pred_i(i+1) = rt_explore;
%             else
%                 %grw
%                 exptxt='grw explore';
%                 rt_grw = rt_obs(i) + grw_step; %use GRW around prior *observed* RT
%                 
%                 %N.B.: Need to have more reasonable GRW near the edge such that it doesn't just oversample min/max
%                 %e.g., perhaps reflect the GRW if rt(t-1) was already very close to edge and GRW samples in that
%                 %direction again.                
%                 if rt_grw > max(tvec), rt_grw = max(tvec);
%                 elseif rt_grw < min(tvec), rt_grw = min(tvec); end
%                 rt_pred_i(i+1) = rt_grw;
%             end
            explore_trials = [explore_trials i+1];
        else
            exptxt='exploit';%for graph annotation
            rt_pred_i(i+1) = rt_exploit;
            exploit_trials = [exploit_trials i+1]; %predict next RT on the basis of explore/exploit
        end 
        
        %playing with basis update at the edge
        %rt_pred_i(i+1) = randi([400,500],1); %force to late times
    
    end
    
    rts_pred_explore(i+1) = rt_explore;
    rts_pred_exploit(i+1) = rt_exploit;

    %don't compute distance on first trial
    if (i > 1)
        %compute deviation between next observed RT and model-predicted RT
        %use the 2-D Euclidean distance between RT_obs and RT_pred in U and Q space (roughly related to the idea
        %of bivariate kernel density).
        
        %normalize V and U vector to unit lengths so that costs do not scale with changes in the absolute
        %magnitude of these functions... I believe this is right: discuss with AD.
        
        vnorm=v_it(i,:)/sqrt(sum(v_it(i,:))^2);
        unorm=u_it(i,:)/sqrt(sum(u_it(i,:))^2);
        
        %I believe we should use i for this, not i+1 so that we are always comparing the current RT with the
        %predicted current RT. Technically, the predicted RT was computed on the prior iteration of the loop, but
        %in trial space, both are current/i.
        %place RTs into U and Q space
        d_i(i) = sqrt( (v_it(i, rt_obs(i)) - v_it(i, rt_pred_i(i))).^2 + (u_it(i, rt_obs(i)) - u_it(i, rt_pred_i(i))).^2);
        
        %d_i(i) = sqrt( (vnorm(rt_obs(i)) - vnorm(rt_pred_i(i))).^2 + (unorm(rt_obs(i)) - unorm(rt_pred_i(i))).^2)
                
        %weight cost by model-predicted probability of exploration. Use absolute deviation from 0.5 as measure of
        %uncertainty about exploration/exploitation, and use the deviation as the power (0..1) to which the
        %distance is exponentiated.
        
        %.1 power is a hack for now to make the falloff in cost slower near the edges (not just inverted triangle)
        precision_i(i) = (abs(p_explore_i(i) - 0.5)/0.5)^.1; %absolute symmetric deviation from complete uncertainty
        
        %r=100;
        %probs=0:0.01:1;
        %precision=arrayfun(@(p) abs(p - 0.5)/0.5, probs).^.1;
        %dr=r.^precision;
        %plot(probs, dr)
        
        %note that this multiplying d_i by precision_i gives an inverted triangle where cost = 0 at 0.5
        %probably want something steeper so that only costs ~0.4-0.6 are severely downweighted
        d_i(i) = d_i(i)^precision_i(i); %downweight costs where model is ambivalent about explore/exploit
        
    end
    
    extra_plots = 0;
    figure(11);
    if(extra_plots == 1 && ~all(v_it(i,:)) == 0)
        gkde2(vertcat(v_it(i,:), u_it(i,:)));
        %gkde2(vertcat(vnorm, unorm))
    end
    
    %compute the expected returns for the observed and predicted choices
    if (nargin >= 8)
        [~, ev_obs_i(i)] = RewFunction(rt_obs(i).*10, cond); %multiply by 10 because underlying functions range 0-5000ms
        [~, ev_pred_i(i)] = RewFunction(rt_obs(i).*10, cond); %multiply by 10 because underlying functions range 0-5000ms
    end
    
    verbose=0;
    if verbose == 1
       fprintf('Trial: %d, Rew(i): %.2f, Rt(i): %.2f\n', i, rew_obs(i), rt_obs(i));
       fprintf('w_i,k:    '); fprintf('%.2f ', mu_ij(i,:)); fprintf('\n');
       fprintf('delta_ij:   '); fprintf('%.2f ', delta_ij(i,:)); fprintf('\n');
       fprintf('w_i+1,k:  '); fprintf('%.2f ', mu_ij(i+1,:)); fprintf('\n');
       fprintf('\n');
       
    end
    
    if trial_plots == 1
%         figure(1); clf;
%         subplot(5,2,1)
%         %plot(tvec,v_func);
%         scatter(rt_pred_i(1:i),rew_obs(1:i)); axis([1 500 0 350]);
%         hold on;
%         plot(rt_pred_i(i),rew_obs(i),'r*','MarkerSize',20);  axis([1 500 0 350]);
%         hold off;
%         subplot(5,2,2)
%         plot(tvec,v_func); xlim([-1 ntimesteps+1]);
%         ylabel('value')
%         subplot(5,2,3)
%         
% %         bar(c, mu_ij(i,:));
% %         ylabel('basis function heights');
%         plot(tvec,v_jt);
%         ylabel('temporal basis function')
% %         title(sprintf('trial # = %i', h)); %
%                 xlabel('time(ms)')
%                 ylabel('reward value')
%         
%         subplot(5,2,4)
%         plot(tvec, u_func, 'r'); xlim([-1 ntimesteps+1]);
%         xlabel('time (centiseconds)')
%         ylabel('uncertainty')
%         
%         subplot(5,2,5)
%         barh(sigmoid);
%         xlabel('p(explore)'); axis([-.1 1.1 0 2]);
%         subplot(5,2,6)
%         %barh(alpha), axis([0 .2 0 2]);
%         %xlabel('learning rate')
%         subplot(5,2,7)
%         barh(sig_spread), axis([0.0 0.5 0 2]);
%         xlabel('decay')
%         subplot(5,2,8)
%         barh(epsilon), axis([-0.5 0 0 2]);
%         xlabel('strategic exploration')
%         
%         subplot(5,2,9)
%         barh(u) %, axis([0 1000 0 2]);
%         xlabel('mean uncertainty')
%         %         pause(0.1);
%         subplot(5,2,10)
%         plot(1:ntrials,rt_pred_i, 'k');
%         ylabel('rt by trial'); axis([1 ntrials -5 505]);
        
        figure(1); clf;
        set(gca,'FontSize',18);
        subplot(3,2,1);
        title('Choice history');
        %plot(tvec,v_func);
        scatter(rt_obs(1:i),rew_obs(1:i)); axis([1 ntimesteps 0 350]);
        hold on;
        plot(rt_obs(i),rew_obs(i),'r*','MarkerSize',20);  axis([1 ntimesteps 0 350]);
        hold off;
        subplot(3,2,2)
        title('Learned value');
        plot(tvec,v_func); xlim([-1 ntimesteps+1]);
        ylabel('expected value')
%         bar(c, mu_ij(i,:));
%         ylabel('basis function heights');
        %title('basis function values');
        %plot(tvec,v_jt);
        %ylabel('temporal basis function')
%         title(sprintf('trial # = %i', h)); %
        
        subplot(3,2,3);        
        scatter(rt_pred_i(1:i),rew_obs(1:i)); axis([1 ntimesteps 0 350]);
        text(20, max(rew_obs), exptxt);
        hold on;
        plot(rt_pred_i(i),rew_obs(i),'r*','MarkerSize',20);  axis([1 ntimesteps 0 350]);
        hold off;
        
        subplot(3,2,4);
        plot(tvec, u_func, 'r'); xlim([-1 ntimesteps+1]);
        xlabel('time (centiseconds)')
        ylabel('uncertainty')
        
        subplot(3,2,5);      
        %eligibility trace
        title('eligibility trace');
        %elig_plot = sum(repmat(elig,nbasis,1).*gaussmat_trunc, 1);
        %plot(tvec, elig_plot);
        plot(tvec, elig);
        xlabel('time(centiseconds)')
        ylabel('eligibility')
        
        
        subplot(3,2,6);
        plot(1:length(rt_obs), rt_obs, 'r');
        hold on;
        plot(1:length(rts_pred_exploit), rts_pred_exploit, 'b');
        plot(1:length(rts_pred_explore), rts_pred_explore, 'k');
        hold off;
        
        %figure(2); clf;
        %plot(tvec, u_func);
        %hold on;
        %plot(c, e_ij(i,:))
        %plot(c, e_ij(1:i,:)')
        %bar(c, sigma_ij(i,:))

        drawnow update;
        mov(i) = getframe(gcf);
    end
    %     disp([i rt_pred_i(i) rew_obs(i) sum(v_func)])
end
cost = -sum(d_i); %minimize euclidean distances
ret.mu_ij = mu_ij;
ret.sigma_ij = sigma_ij;
ret.k_ij = k_ij;
ret.delta_ij = delta_ij;
ret.e_ij = e_ij;
ret.v_it = v_it;
ret.u_it = u_it;
ret.rew_obs = rew_obs;
ret.ev_obs_i = ev_obs_i;
ret.ev_pred_i = ev_pred_i;
ret.rt_obs = rt_obs;
ret.rt_pred_i = rt_pred_i;
ret.rts_pred_explore = rts_pred_explore;
ret.rts_pred_exploit = rts_pred_exploit;
ret.explore_trials = explore_trials;
ret.exploit_trials = exploit_trials;
ret.d_i = d_i;
ret.p_explore_i = p_explore_i;

%ret.cost_explore = -sum((rt_pred_i(explore_trials) - rt_obs(explore_trials)).^2);
%ret.cost_exploit = -sum((rt_pred_i(exploit_trials) - rt_obs(exploit_trials)).^2);



