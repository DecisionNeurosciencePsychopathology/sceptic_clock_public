function  [fx] = h_sceptic_fixed_decay(x_t, theta, u, inF)
% evolution function of 'fixed_decay' flavor of SCEPTIC
% IN:
%   - x_t : basis values/heights (nbasis x 1)
%   - theta : theta(1) = alpha;
%             NOTE: if fit propspread should always be the last parameter of theta
%   - u : u(1) = rt; u(2) = reward
%   - inF : struct of input options (has nbasis and ntimesteps)
% OUT:
%   - fx: evolved basis values/heights (nbasis x 1)

alpha = 1./(1+exp(-theta(1))); %LR: 0..1
gamma = 1./(1+exp(-theta(2))); %Decay: 0..1

if inF.fit_propspread
    prop_spread = 1./(1+exp(-theta(3))); %0..1 SD of Gaussian eligibility as proportion of interval
    sig_spread=prop_spread*range(inF.tvec); %determine SD of spread function in time units (not proportion)
    
    %if prop_spread is free, then refspread must be recomputed to get AUC of eligibility correct
    refspread = sum(gaussmf(min(inF.tvec)-range(inF.tvec):max(inF.tvec)+range(inF.tvec), [sig_spread, median(inF.tvec)]));
else
    sig_spread = inF.sig_spread; %precomputed sig_spread based on fixed prop_spread (see setup_rbf.m)
    refspread = inF.refspread; %precomputed refspread based on fixed prop_spread
end

rt = u(1);
reward = u(2);

if inF.fit_nbasis
    % convert normally distributed theta(2) to discrete uniform number of bases
    nbasis_cdf = cdf('Normal',theta(2),inF.muTheta2, inF.SigmaTheta2);
    nbasis = unidinv(nbasis_cdf,inF.maxbasis);
else
    nbasis = inF.nbasis;
end

ntimesteps = inF.ntimesteps;
gaussmat=inF.gaussmat;
v=x_t(1:nbasis)*ones(1,ntimesteps) .* gaussmat; %use vector outer product to replicate weight vector
v_func = sum(v);

%Create index vectors
hidden_state_index=1:inF.hidden_state*nbasis;
hidden_state_index = reshape(hidden_state_index,nbasis,inF.hidden_state);

%compute gaussian spread function with mu = rts(i) and sigma based on free param prop_spread
elig = gaussmf(inF.tvec, [sig_spread, rt]);

%compute sum of area under the curve of the gaussian function
auc=sum(elig);

%divide gaussian update function by its sum so that AUC=1.0, then rescale to have AUC of a non-truncated basis
%this ensures that eligibility is 0-1.0 for non-truncated update function, and can exceed 1.0 at the edge.
%note: this leads to a truncated gaussian update function defined on the interval of interest because AUC
%will be 1.0 even for a partial Gaussian where part of the distribution falls outside of the interval.
elig=elig/auc*refspread;

%compute the intersection of the Gaussian spread function with the truncated Gaussian basis.
%this is essentially summing the area under the curve of each truncated RBF weighted by the truncated
%Gaussian spread function.
e = sum(repmat(elig,nbasis,1).*inF.gaussmat_trunc, 2);


%If we want the entropy run the function here
% threshold = inF.H_threshold; %Add in threshold to value
% active_elements = x_t(1:nbasis)>threshold;
%H = wentropy(x_t(active_elements),'log energy'); %Entropy
%H = wentropy(x_t(active_elements),'shannon'); %Entropy
H = calc_shannon_H( (x_t(1:nbasis)/sum(x_t(1:nbasis))) ); %Entropy
%max_value = max(x_t(1:nbasis)); %Max value pre update


%1) compute prediction error, scaled by eligibility trace
if (exist('inF.total_pe') && inF.total_pe==1 )  %Niv version
    rnd_rt = round(rt);
    
    if rnd_rt==0
        rnd_rt=1;
    elseif rnd_rt>40
        rnd_rt=40;
    end
    delta = e*(reward - v_func(round(rnd_rt)));
else
    delta = e.*(reward - x_t(1:nbasis));
end


%% introduce decay
decay = -gamma.*(1-e).*x_t(1:nbasis);

fx = x_t(1:nbasis) + alpha.*delta + decay;

% The try catches are in place for refitting purposes of older datasets
% that never had the following options

%track pe as a hidden state (if applicable)
try
    if inF.track_pe
        fx(hidden_state_index(:,end))=delta;
    end
catch
end

%Track entropy (if applicable)
try
    if inF.entropy
        H = is_nan_or_inf(H);
        %max_value = is_nan_or_inf(max_value);
        max_value = find_max_value_in_time(v_func);
        fx(hidden_state_index(end)+1) = H;
        fx(hidden_state_index(end)+2) = max_value;
    end
catch
end


%Track choice decay (if applicable)
try
    if strcmp(inF.autocorrelation,'choice_tbf')
        choice_decay = 1./(1+exp(-theta(end)));
        fx = x_t(1:nbasis) + alpha.*delta + decay;
        fx(length(x_t)-nbasis+1:length(x_t)) = choice_decay.*x_t(length(x_t)-nbasis+1:end) + e;
    end
catch
end

function out = is_nan_or_inf(var)
if isnan(var) || isinf(var)
    out=0;
else
    out=var;
end


function time_point = find_max_value_in_time(val)
max_val  = max(val); %Get the max value
time_point = find(max_val==val); %Find the max
if length(time_point)>1 %If there are duplicates randomly select one
    time_point = randsample(time_point,1);
end